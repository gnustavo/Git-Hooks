# Git::Hooks

A Perl framework for implementing Git (and Gerrit) hooks.

## What's this about?

[Git hooks](http://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks) are
programs you install in Git repositories in order to augment Git's
functionality.

The Git::Hooks Perl module is a framework that makes it easier to implement and
use Git hooks. It comes with a set of plugins already implementing useful
functionality for you to make sure your commits comply with your project
policies. As a Git user or a Git server administrator you probably don't need to
implement any hooks for most of your needs, just to enable and configure some of
the existing plugins.

## Installation

Git::Hooks is installed like any other Perl module. It's easier to use a CPAN
client, such as `cpanm` or `cpan`, so that dependencies are installed
automatically:

    $ cpanm Git::Hooks
    $ cpan Git::Hooks

You can even use it directly from a clone of its Git repository. All you have to
do is to tell Perl where to find it by using this in your scripts:

    use lib '/path/to/clone/of/git-hooks/lib';
    use Git::Hooks;

Another option is to run your hooks in a Docker container, so that you don't
need to really install it. Read the Docker section of the
[Git::Hooks::Tutorial](https://metacpan.org/dist/Git-Hooks/view/lib/Git/Hooks/Tutorial.pod)
to know how to do it.

## Documentation

The main module documents its [usage](https://metacpan.org/pod/Git%3A%3AHooks)
in detail. Each plugin is implemented as a separate module under the
`Git::Hooks::` name space. Git::Hooks distribution comes with a set of plugins
and you can find more on
[CPAN](https://metacpan.org/search?q=module%3AGit%3A%3AHooks). The native
plugins provided by the distribution are these:

- [Git::Hooks::CheckCommit](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ACheckCommit) -
  enforce commit policies
- [Git::Hooks::CheckDiff](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ACheckDiff) -
  check differences between commits
- [Git::Hooks::CheckFile](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ACheckFile) -
  check file names and contents
- [Git::Hooks::CheckJira](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ACheckJira) -
  integrate with [Jira](https://www.atlassian.com/software/jira)
- [Git::Hooks::CheckLog](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ACheckLog) -
  enforce log message policies
- [Git::Hooks::CheckReference](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ACheckReference) -
  check reference names
- [Git::Hooks::CheckRewrite](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ACheckRewrite) -
  protect against unsafe rewrites
- [Git::Hooks::CheckWhitespace](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ACheckWhitespace) -
  detect whitespace errors
- [Git::Hooks::GerritChangeId](https://metacpan.org/pod/Git%3A%3AHooks%3A%3AGerritChangeId) -
  insert Gerrit's Change-Ids into commit messages
- [Git::Hooks::Notify](https://metacpan.org/pod/Git%3A%3AHooks%3A%3ANotify) -
  notify users via email
- [Git::Hooks::PrepareLog](https://metacpan.org/pod/Git%3A%3AHooks%3A%3APrepareLog) -
  prepare commit messages before being edited

For a gentler introduction you can read our
[Git::Hooks::Tutorial](https://metacpan.org/dist/Git-Hooks/view/lib/Git/Hooks/Tutorial.pod).
It has instructions for Git users, Git administrators, and Gerrit
administrators.

## Getting Help

In order to ask questions or to report problems, please, [file an issue at
GitHub](https://github.com/gnustavo/Git-Hooks/issues).

## Copyright & License

Git::Hooks is copyright (c) 2008-2022 of [CPQD](http://www.cpqd.com.br).

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language system itself. About the only thing you
can't do is pretend that you wrote code that you didn't.

## Enjoy!

Gustavo Chaves <gnustavo@cpan.org>
