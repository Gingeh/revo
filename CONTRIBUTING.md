# contributing

thank you for considering contributing to revo

the project is so young, that even taking a stroll through any source file might yield you a good observation

a contribution anything from a pull request to an issue or a suggestion, all contributions are welcome!

## where to start

- check out [TODO.md](./TODO.md) for plans and pick an issue
- see ./issues

you can contribute via github, codeberg or via [emailing me a .patch](mailto:lung-notification@proton.me)

the commit etiquette is influenced by that of
[the linux jernel](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/log/)
(they have [a whole page](https://www.kernel.org/doc/html/v4.14/process/submitting-patches.html#describe-your-changes)) on that)

- every commit should at least compile
- its fine if something doesnt work in the middle of a commit chain, as long as it works by the final one
- formatted like

    ```text
    lang+repl!+diag: fix occasional combustion
    # if multiple scopes, list with + to separate them
    # if breaking change, use !

    repl would sometimes spit out nuclear codes

    fixed GH-1337 # for github issues, use GH-12 rather than #12
    ```

## about AI-generated code

please do not submit LLM-authored code if you do not understand it, can't explain it or have not tested it
do not submit english AI-generated or translated text at all. this goes for issues as well
if you don't know the language - that's fine, just submit it in your native language and i'll translate it manually
do not submit walls of AI-generated code and instead describe it in your own words
this greatly reduces maintenance burden

if you submit an AI-assisted or AI-generated pull request, clearly mark it as such

do not advertise in git history - that is, do not leave a model/vendor name in the details

if you make a functional change, the correctness should also be verified by a test
