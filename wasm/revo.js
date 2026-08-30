/**
 * @fileoverview the revo language runtime
 *
 * each {@link Revo} object wraps an independent wasm instance with its
 * own linear memory and VM state
 *
 * @example
 * ```js
 * import { Revo } from './lib/revo.js'
 *
 * const revo = await Revo.create({ wasmUrl: '/revo.wasm' })
 * const r = revo.eval('print("hello")')
 * console.log(r.ok, r.value)
 * revo.destroy()
 * ```
 *
 * @example
 * ```js
 * // nodejs: preload the wasm binary
 * import { readFileSync } from 'fs'
 * import { Revo } from './lib/revo.js'
 *
 * const buf = readFileSync('./revo.wasm')
 * const revo = await Revo.fromBuffer(buf)
 * console.log(revo.eval('1 + 2').value)
 * revo.destroy()
 * ```
 * @module revo
 */

const OUT_SIZE = 65536
const ENOSYS = 52

/** module-level cache of compiled wasm, keyed by url */
const compiledModuleCache = new Map()

const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, '')

function decodeUtf8(memory, ptr, len) {
	return new TextDecoder().decode(new Uint8Array(memory.buffer, Number(ptr), Number(len)))
}

/** same as {@link decodeUtf8} but also strips ansi codes, for use with wasi output */
function decodeWasiText(memory, ptr, len) {
	return stripAnsi(decodeUtf8(memory, ptr, len))
}

export class RevoError extends Error {
	/** @param {string} msg */
	constructor(msg) {
		super(msg)
		this.name = 'RevoError'
	}
}

/**
 * @typedef {Object} RevoOptions
 * @property {string} [wasmUrl='./revo.wasm'] - url to the wasm binary.
 *   in the browser resolves relative to the page, not the module.
 * @property {(text: string) => void} [stdout] - stdout callback (print etc.)
 * @property {(text: string) => void} [stderr] - stderr callback
 * @property {number} [outSize=65536] - max bytes for the eval result
 */

/**
 * @typedef {Object} EvalResult
 * @property {boolean} ok    - true = success, false = compile/runtime error
 * @property {string}  value - formatted result or error text
 */

/** fetches raw wasm bytes from a url, in the browser or in node */
async function fetchWasmBytes(url) {
	if (typeof fetch !== 'undefined') {
		const resp = await fetch(url)
		if (!resp.ok) throw new RevoError(`fetch failed: ${resp.status} ${resp.statusText}`)
		return await resp.arrayBuffer()
	}
	const fs = await import('fs')
	return fs.readFileSync(url).buffer
}

/** compiles a wasm module, reusing a cached compile for the same url */
async function compileFromUrl(url) {
	let mod = compiledModuleCache.get(url)
	if (!mod) {
		const bytes = await fetchWasmBytes(url)
		mod = await WebAssembly.compile(bytes)
		compiledModuleCache.set(url, mod)
	}
	return mod
}

/**
 * minimal wasi_snapshot_preview1 implementation for environments without
 * a real wasi shim
 * only implements what revo actually needs; everything else reports ENOSYS
 *
 * @param {Revo} self - used for its _stdout/_stderr callbacks
 * @param {() => WebAssembly.Memory | null} getMemory - lazily reads memory,
 *   since it is not available until after instantiation
 */
function freestandingWasi(self, getMemory) {
	const enosys = () => ENOSYS

	const impl = {
		fd_write(fd, iovsPtr, iovsLen, nWrittenPtr) {
			const memory = getMemory()
			if (!memory) return ENOSYS
			const view = new DataView(memory.buffer)
			let written = 0
			for (let i = 0; i < Number(iovsLen); i++) {
				const base = Number(iovsPtr) + i * 8
				const ptr = view.getUint32(base, true)
				const len = view.getUint32(base + 4, true)
				written += len
				const text = decodeWasiText(memory, ptr, len)
				if (fd === 2) self._stderr(text)
				else self._stdout(text)
			}
			view.setUint32(Number(nWrittenPtr), written, true)
			return 0
		},
		random_get(ptr, len) {
			const memory = getMemory()
			if (!memory) return ENOSYS
			crypto.getRandomValues(new Uint8Array(memory.buffer, Number(ptr), Number(len)))
			return 0
		},
		clock_time_get(_clockId, _precision, ptr) {
			const memory = getMemory()
			if (!memory) return ENOSYS
			new DataView(memory.buffer).setBigUint64(Number(ptr), BigInt(Date.now()) * 1000000n, true)
			return 0
		},
		clock_res_get(_clockId, ptr) {
			const memory = getMemory()
			if (!memory) return ENOSYS
			new DataView(memory.buffer).setBigUint64(Number(ptr), 1000000n, true)
			return 0
		},
		args_sizes_get(countPtr, bufSizePtr) {
			const memory = getMemory()
			if (!memory) return ENOSYS
			const view = new DataView(memory.buffer)
			view.setUint32(Number(countPtr), 0, true)
			view.setUint32(Number(bufSizePtr), 0, true)
			return 0
		},
		args_get() { return 0 },
		environ_sizes_get(countPtr, bufSizePtr) {
			const memory = getMemory()
			if (!memory) return ENOSYS
			const view = new DataView(memory.buffer)
			view.setUint32(Number(countPtr), 0, true)
			view.setUint32(Number(bufSizePtr), 0, true)
			return 0
		},
		environ_get() { return 0 },
		proc_exit(code) { throw new RevoError(`proc_exit(${code})`) },
	}

	// any wasi import not listed above resolves to a stub that reports ENOSYS,
	// instead of throwing "no such import" at instantiation time
	return new Proxy(impl, { get: (target, prop) => (prop in target ? target[prop] : enosys) })
}

/**
 * picks a real wasi shim when running in the browser, falling back to
 * {@link freestandingWasi} everywhere else (or if the shim fails to load)
 *
 * @param {Revo} self
 * @param {() => WebAssembly.Memory | null} getMemory
 */
async function resolveWasiImport(self, getMemory) {
	if (typeof window !== 'undefined') {
		try {
			const { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory } = await import('@bjorn3/browser_wasi_shim')
			const fds = [
				new OpenFile(new File([])),
				ConsoleStdout.lineBuffered((line) => self._stdout(line)),
				ConsoleStdout.lineBuffered((line) => self._stderr(line)),
				new PreopenDirectory('/', []),
			]
			const wasi = new WASI([], [], fds)
			return { wasi, imports: wasi.wasiImport }
		} catch {
			// fall through to the freestanding stub below
		}
	}
	return { wasi: null, imports: freestandingWasi(self, getMemory) }
}

/**
 * a revo vm in its own wasm instance
 *
 * use {@link Revo.create} or {@link Revo.fromBuffer} - don't call the constructor
 */
export class Revo {
	/**
	 * fetch and compile wasm from a url, then instantiate
	 *
	 * compiled modules are cached by url; only instantiation is per-instance
	 *
	 * @param {RevoOptions} [opts]
	 * @returns {Promise<Revo>}
	 */
	static async create(opts = {}) {
		const wasmUrl = opts.wasmUrl || './revo.wasm'
		const mod = await compileFromUrl(wasmUrl)
		const revo = new this(opts)
		await revo._instantiate(mod)
		return revo
	}

	/**
	 * compile and instantiate from a preloaded buffer
	 *
	 * @param {ArrayBuffer | Uint8Array} buffer - raw wasm bytes
	 * @param {RevoOptions} [opts]
	 * @returns {Promise<Revo>}
	 */
	static async fromBuffer(buffer, opts = {}) {
		const mod = await WebAssembly.compile(buffer)
		const revo = new this(opts)
		await revo._instantiate(mod)
		return revo
	}

	/**
	 * do not call directly!!! use the static factories
	 * @private
	 * @param {RevoOptions} opts
	 */
	constructor(opts = {}) {
		/** @private */ this._instance = null
		/** @private */ this._exports = null
		/** @private */ this._memory = null
		/** @private */ this._outSize = opts.outSize || OUT_SIZE
		/** @private */ this._stdout = opts.stdout || (() => { })
		/** @private */ this._stderr = opts.stderr || (() => { })
	}

	/**
	 * instantiate the module with plain env imports (js_write_stdout / stderr)
	 *
	 * the env closures capture `memory` by reference, which is only set once
	 * instantiation finishes -- wasm imports have to be resolved before we
	 * have the instance's memory export to read from
	 *
	 * @private
	 * @param {WebAssembly.Module} mod
	 */
	async _instantiate(mod) {
		let memory = null
		const env = {
			js_write_stdout: (ptr, len) => this._stdout(decodeUtf8(memory, ptr, len)),
			js_write_stderr: (ptr, len) => this._stderr(decodeUtf8(memory, ptr, len)),
		}

		const instance = await WebAssembly.instantiate(mod, { env })
		memory = instance.exports.memory

		this._memory = memory
		this._instance = instance
		this._exports = instance.exports

		if (!this._exports.revo_wasm_init()) throw new RevoError('revo_wasm_init returned false')
	}

	/**
	 * converts a plain JS number into whatever numeric type the wasm exports
	 * expect for pointers/lengths. the base build is always wasm64, so it is
	 * always BigInt; {@link WasiRevo} overrides this to autodetect wasm32.
	 * @protected
	 * @param {number} n
	 */
	_num(n) {
		return BigInt(n)
	}

	/**
	 * allocates `n` bytes in the vm and returns the pointer
	 * @private
	 */
	_alloc(n) {
		const ptr = this._exports.revo_wasm_alloc(this._num(n))
		if (Number(ptr) === 0) throw new RevoError('allocation failed')
		return ptr
	}

	/** @private */
	_free(ptr, n) {
		this._exports.revo_wasm_free(ptr, this._num(n))
	}

	/**
	 * shared implementation behind {@link eval} and (on {@link WasiRevo})
	 * `check`: writes `code` into vm memory, calls the given export, reads
	 * the result back out, and frees both buffers
	 *
	 * @private
	 * @param {string} exportName - e.g. 'revo_wasm_eval' or 'revo_wasm_check'
	 * @param {string} code
	 * @param {{ strip?: boolean }} [options] - strip ansi codes from the result
	 * @returns {EvalResult}
	 */
	_run(exportName, code, { strip = false } = {}) {
		if (!this._exports) throw new RevoError('revo instance is gone')
		if (code.length === 0) return { ok: true, value: '' }

		const memory = this._memory
		const source = new TextEncoder().encode(code)

		const srcPtr = this._alloc(source.length)
		try {
			new Uint8Array(memory.buffer).set(source, Number(srcPtr))

			const outCap = this._outSize
			const outPtr = this._alloc(outCap)
			try {
				const fn = this._exports[exportName]
				const n = Number(fn(srcPtr, this._num(source.length), outPtr, this._num(outCap)))
				const ok = this._exports.revo_wasm_ok()

				let value = ''
				if (n > 0) {
					const raw = decodeUtf8(memory, outPtr, Math.min(n, outCap))
					value = strip ? stripAnsi(raw) : raw
				}
				return { ok, value }
			} finally {
				this._free(outPtr, outCap)
			}
		} finally {
			this._free(srcPtr, source.length)
		}
	}

	/**
	 * evaluate revo source and return the formatted result
	 *
	 * @param {string} code - revo source (one or more expressions)
	 * @returns {EvalResult}
	 * @throws {RevoError} on internal failure (oom, destroyed instance)
	 */
	eval(code) {
		return this._run('revo_wasm_eval', code)
	}

	/**
	 * re-init the vm (clears globals, reregisters stdlib)
	 *
	 * calls revo_wasm_deinit + revo_wasm_init on the same instance
	 *
	 * @throws {RevoError} on reinit failure
	 */
	reset() {
		if (!this._exports) throw new RevoError('revo instance is gone')
		this._exports.revo_wasm_deinit()
		if (!this._exports.revo_wasm_init()) throw new RevoError('revo_wasm_init returned false')
	}

	/**
	 * raw wasm exports (alloc, free, ok, etc.)
	 * @returns {WebAssembly.Exports | null}
	 */
	get raw() {
		return this._exports
	}

	/**
	 * tear down the wasm instance
	 */
	destroy() {
		if (this._exports) {
			try {
				this._exports.revo_wasm_deinit()
			} catch {
				// instance may already be trapped; nothing more we can do
			}
		}
		this._exports = null
		this._instance = null
		this._memory = null
	}
}

/**
 * wasi32 build
 * uses browser_wasi_shim when available, otherwise
 * freestanding stubs. shares same `Revo` API but defaults to
 * `revo-wasi.wasm`, adds a typecheck-only `check` method
 */
export class WasiRevo extends Revo {
	static async create(opts = {}) {
		const wasmUrl = opts.wasmUrl || '/engine/revo-wasi.wasm'
		const mod = await compileFromUrl(wasmUrl)
		const revo = new this(opts)
		await revo._instantiate(mod)
		return revo
	}

	/**
	 * @private
	 * @param {WebAssembly.Module} mod
	 */
	async _instantiate(mod) {
		let memory = null
		const self = this

		const { wasi, imports: wasiImports } = await resolveWasiImport(self, () => memory)
		const wasiProxy = new Proxy(wasiImports, {
			get: (target, prop) => (prop in target ? target[prop] : () => ENOSYS),
		})

		const imports = {
			env: {
				js_write_stdout: (ptr, len) => self._stdout(decodeWasiText(memory, ptr, len)),
				js_write_stderr: (ptr, len) => self._stderr(decodeWasiText(memory, ptr, len)),
			},
			wasi_snapshot_preview1: wasiProxy,
		}

		// stub out any other imported module so instantiation never fails
		// on an unrelated missing import
		for (const imp of WebAssembly.Module.imports(mod)) {
			if (imp.module === 'env' || imp.module === 'wasi_snapshot_preview1') continue
			imports[imp.module] ??= {}
			imports[imp.module][imp.name] ??= () => ENOSYS
		}

		const instance = await WebAssembly.instantiate(mod, imports)
		memory = instance.exports.memory

		this._memory = memory
		this._instance = instance
		this._exports = instance.exports
		this._wasi = wasi

		if (this._wasi) {
			if (this._wasi.initialize) this._wasi.initialize(instance)
			else this._wasi.inst = instance
		}

		this._is64 = this._detectPointerWidth()

		if (!this._exports.revo_wasm_init()) throw new RevoError('revo_wasm_init failed')
	}

	/**
	 * wasm32 exports use plain numbers for pointers, wasm64 uses BigInt;
	 * probe a real export to find out which this build is
	 * @private
	 */
	_detectPointerWidth() {
		try {
			const ptr = this._exports.revo_wasm_alloc(BigInt(1))
			const is64 = typeof ptr === 'bigint'
			this._exports.revo_wasm_free(ptr, is64 ? BigInt(1) : 1)
			return is64
		} catch {
			return false
		}
	}

	/** @protected @override */
	_num(n) {
		return this._is64 ? BigInt(n) : Number(n)
	}

	/**
	 * typecheck only, does not run the program
	 * @param {string} code
	 * @returns {EvalResult}
	 */
	check(code) {
		const exportName = this._exports.revo_wasm_check ? 'revo_wasm_check' : 'revo_wasm_eval'
		return this._run(exportName, code, { strip: true })
	}

	/** @override */
	eval(code) {
		return this._run('revo_wasm_eval', code, { strip: true })
	}
}

export const FreestandingRevo = Revo
export default WasiRevo

/**
 * makes vm, runs code, destroys vm
 *
 * @param {string} code - revo source
 * @param {RevoOptions & { wasmBuffer?: ArrayBuffer | Uint8Array, useWasi?: boolean }} [opts]
 *   opts are passed to {@link Revo.create}, or if `wasmBuffer` is set
 *   uses {@link Revo.fromBuffer} instead
 * @returns {Promise<EvalResult>}
 */
export async function run(code, opts = {}) {
	const { wasmBuffer, useWasi, ...rest } = opts
	const Impl = useWasi ? WasiRevo : Revo
	const revo = wasmBuffer ? await Impl.fromBuffer(wasmBuffer, rest) : await Impl.create(rest)
	try {
		return revo.eval(code)
	} finally {
		revo.destroy()
	}
}
