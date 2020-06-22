# Paucal

A WIP supplementary bot for PluralKit.

# Contributing

You'll need [The Nix Package Manager](https://nixos.org/) for dependency/build management. Paucal is written in [Crystal](https://crystal-lang.org).
```
$ git clone git@github.com:deingithub/paucal
$ cd paucal
$ nix-shell
[nix-shell]$ sqlite3 paucal.db ".read schema.sql"
[nix-shell]$ crystal run src/Paucal.cr
```

You'll need to provide a `.env` in the project root, use `.env.example` as a template.

# Overview
Paucal consists out of one *Parent bot* and many *Member bots*, all of which are started on initialization. The parent (src/Parent.cr) does most of the work and delegates all tasks that require a member bot to them (src/Member.cr) via channels. Unless unavoidable, member bots don't have their own event handlers and just react to these messages. Data classes for various things are stored in src/Models.cr. The entry point is in src/Paucal.cr.