# PROGRAMMING

This file documents things you should know to write a new debhelper program.
Any program with a name that begins with `dh_` should conform to these
guidelines (with the historical exception of `dh_make`).

## Standardization

There are lots of debhelper commands. To make the learning curve shallower,
I want them all to behave in a standard manner:

All debhelper programs have names beginning with `dh_`. This is so we don't
pollute the name space too much.

Debhelper programs should never output anything to standard output except
error messages, important warnings, and the actual commands they run that
modify files under `debian/` (this last only if they are passed `-v`, and if you
output the commands, you should indent them with 1 tab). This is so we don't
have a lot of noise output when all the debhelper commands in a `debian/rules`
are run, so the important stuff is clearly visible.

An exception to above rule are `dh_auto_*` commands and `dh` itself. They will
also print the commands interacting with the upstream build system and which
of the simple debhelper programs are called. (i.e. print what a traditional
non-[dh(1)] using `debian/rules` would print but nothing else).

Debhelper programs should accept all options listed in the "SHARED
DEBHELPER OPTIONS" section of [debhelper(7)], including any long forms of
these options, like `--verbose`. If necessary, the options may be ignored.

If debhelper commands need config files, they should use
`debian/package.filename` as the name of the config file (replace filename
with whatever your command wants), and `debian/filename` should also be
checked for config information for the first binary package in
`debian/control`. Also, debhelper commands should accept the same sort of
information that appears in the config files, on their command lines, if
possible, and apply that information to the first package they act on.
The config file format should be as simple as possible, generally just a
list of files to act on.

Debhelper programs should never modify the `debian/postinst`, `debian/prerm`,
etc scripts. Instead, they can add lines to `debian/postinst.debhelper`, etc.
The `autoscript()` function (see below) is one easy way to do this.
`dh_installdeb` is an exception, it will run after the other commands and
merge these modifications into the actual postinst scripts.

In general, files named `debian/*.debhelper` and all content in
`debian/.debhelper` are internal to debhelper, and their existence or
use should not be relied on by external programs such as the build
process of a package. These files will be deleted by `dh_clean`.

Debhelper programs should default to doing exactly what policy says to do.

There are always exceptions. Just ask me.

## Introducing Dh_Lib

`Dh_Lib` is the library used by all debhelper programs to parse their
arguments and set some useful variables. It's not mandatory that your
program use `Dh_Lib.pm`, but it will make it a lot easier to keep it in sync
with the rest of debhelper if it does, so this is highly encouraged.

Use `Dh_Lib` like this:

    use Debian::Debhelper::Dh_Lib;
    our $VERSION = '1.0';
    init();

The `init()` function causes `Dh_lib` to parse the command line and do
some other initialization tasks.  If present, `$main::VERSION` will be
used to determine the version of the tool (e.g. embedded into
autoscript snippets).

## Argument processing

All debhelper programs should respond to certain arguments, such as `-v`, `-i`,
`-a`, and `-p`. To help you make this work right, `Dh_Lib.pm` handles argument
processing. Just call `init()`.

You can add support for additional options to your command by passing an
options hash to `init()`. The hash is then passed on the `Getopt::Long` to
parse the command line options. For example, to add a `--foo` option, which
sets `$dh{FOO}`:

    init(options => { foo => \$dh{FOO} });

After argument processing, some global variables are used to hold the
results; programs can use them later. These variables are elements of the
`%dh` hash.

| switch              | variable        | description                                                                                                                                                                                                                      |
|---------------------|-----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `-v`                | `VERBOSE`       | should the program verbosely output what it is doing?                                                                                                                                                                            |
| `--no-act`          | `NO_ACT`        | should the program not actually do anything?                                                                                                                                                                                     |
| `-i`,`-a`,`-p`,`-N` | `DOPACKAGES`    | a space delimited list of the binary packages to act on (in `Dh_Lib.pm`, this is an array)                                                                                                                                       |
| `-i`                | `DOINDEP`       | set if we're acting on binary independent packages                                                                                                                                                                               |
| `-a`                | `DOARCH`        | set if we're acting on binary dependent packages                                                                                                                                                                                 |
| `-n`                | `NOSCRIPTS`     | if set, do not make any modifications to the package's postinst, postrm, etc scripts.                                                                                                                                            |
| `-o`                | `ONLYSCRIPTS`   | if set, only make modifications to the package's scripts, but don't look for or install associated files.                                                                                                                        |
| `-X`                | `EXCLUDE`       | exclude something from processing (you decide what this means for your program) (This is an array)                                                                                                                               |
| `-X`                | `EXCLUDE_FIND`  | same as `EXCLUDE`, except all items are put into a string in a way that they will make find find them. (Use `!` in front to negate that, of course) Note that this should only be used inside `complex_doit()`, not in `doit()`. |
| `-d`                | `D_FLAG`        | you decide what this means to your program                                                                                                                                                                                       |
| `-P`                | `TMPDIR`        | package build directory (implies only one package is being acted on)                                                                                                                                                             |
| `-u`                | `U_PARAMS`      | will be set to a string, that is typically parameters your program passes on to some other program. (This is an array)                                                                                                           |
| `-V`                | `V_FLAG`        | will be set to a string, you decide what it means to your program                                                                                                                                                                |
| `-V`                | `V_FLAG_SET`    | will be 1 if `-V` was specified, even if no parameters were passed along with the `-V`                                                                                                                                           |
| `-A`                | `PARAMS_ALL`    | generally means that additional command line parameters passed to the program (other than those processed here), will apply to all binary packages the program acts on, not just the first                                       |
| `--mainpackage`     | `MAINPACKAGE`   | controls which package is treated as the main package to act on                                                                                                                                                                  |
| `--name`            | `NAME`          | a name to use for installed files, instead of the package name                                                                                                                                                                   |
| `--error-handler`   | `ERROR_HANDLER` | a function to call on error                                                                                                                                                                                                      |

Any additional command line parameters that do not start with "`-`" will be
ignored, and you can access them later just as you normally would.

## Global variables

The following keys are also set in the `%dh` hash when you call `init()`:

- `MAINPACKAGE`

  the name of the first binary package listed in `debian/control`

- `FIRSTPACKAGE`

  the first package we were instructed to act on. This package
  typically gets special treatment; additional arguments
  specified on the command line may effect it.

## Functions

`Dh_Lib.pm` also contains a number of functions you may find useful.

- `doit([$options, ]@command)`

  Pass this function an array that is a command with arguments.
  It will run the command (unless `$dh{NO_ACT}` is set), and
  if `$dh{VERBOSE}` is set, it will also output the command to stdout. You
  should use this function for almost all commands your program performs
  that manipulate files in the package build directories.

  The `$options` argument (if passed) must be a hashref (added in debhelper 10.7).
  The following key-value pairs can be used:

  - `stdout` => A file name.  The child process will have its STDOUT redirected
    to that file.  [debhelper (>= 10.7)]
  - `chdir` => A directory.  The child process will do a chdir into that
    directory before executing the command.  [debhelper (>= 10.9)]
  - `update_env` => A hashref.  Each key in it represents an environment variable
    that should be set in the child (possibly replacing the existing value)
    prior to the exec.  If the value is undef, the environment variable will
    be unset.  Environment variables in `%ENV` but not listed in the `update_env`
    hashref will be preserved as-is.  [debhelper (>= 11.1)]

  This will *not* invoke a shell, so meta characters will not have any special
  meaning.  Use `complex_doit` for that (or emulate via `bash -c`).  
  NB: In compat 11 and below, there was a bug that would make `doit` fork a shell
  in one special case.  This is deprecated and will be removed in compat 12.
  The detection code for this can be disabled by passing an empty hashref for
  as `$options`.  This will make doit unconditionally avoid forking a shell.

- `print_and_doit([$options, ]@command)`

  Like `doit` but will print unless `$dh{QUIET}` is set. See "Standardization"
  above for when this is allowed to be called.

- `complex_doit($command)`

  Pass this function a string that is a shell command, it will run it
  similarly to how `doit()` does. You can pass more complicated commands
  to this (i.e. commands involving piping redirection), however, you
  have to worry about things like escaping shell metacharacters.

- `verbose_print($message)`

  Pass this command a string, and it will echo it if `$dh{VERBOSE}` is set.

- `nonquiet_print($message)`

  Pass this command a string, and it will echo it unless `$dh{QUIET}` is set.
  See "Standardization" above for when this is allowed to be called.

- `error($errormsg)`

  Pass this command a string, it will output it to standard error and
  exit.

- `error_exitcode($cmd)`

  Pass this subroutine a string (representing a command line), it will
  output a message describing that the command failed to standard error
  and exit.  Note that this relies on the value of `$?` to produce a
  meaningful error message.  Even if `$?` is `0`, this *will* still terminate
  the program (although with a rather unhelpful message).

- `warning($message)`

  Pass this command a string, and it will output it to standard error
  as a warning message.

- `tmpdir($dir)`

  Pass this command the name of a binary package, it will return the
  name of the tmp directory that will be used as this package's
  package build directory. Typically, this will be `debian/package`.

- `compat($num)`

  Pass this command a number, and if the current compatibility level
  is less than or equal to that number, it will return true.
  Looks at `DH_COMPAT` to get the compatibility level.

- `pkgfile([$opts,] $package, $basename)`

  Pass this command the name of a binary package, and the base name of a
  file, and it will return the actual filename to use. This is used
  for allowing debhelper programs to have configuration files in the
  `debian/` directory, so there can be one config file per binary
  package. The convention is that the files are named
  `debian/package.filename`, and (until compat 15) `debian/filename`
  is also allowable for the `$dh{MAINPACKAGE}`. If the file does not
  exist, nothing is returned.

  Since debhelper/13.17, if the first argument is a hashref, it is taken
  to be configuration parameter (`$opts`). This hashref can have the
  following keys:

    * `named`: If set to a truth value, the `pkgfile` can have a `name`
      segment. This is only useful if it ever makes sense to have multiple
      files for the same package. This ties to the `--name` parameter
      for the lookup though `--name` can still be used when this is set
      to `false`. The default is `false` at compat 14+ and `true` for
      earlier compat levels.

    * `support-architecture-restriction`: When set to a truth value,
      the `pkgfile` can have an architecture restriction. The is only
      useful if the contents can reasonably be architecture specific.
      The default is `false` at compat 14+ and `true` for earlier
      compat levels.

  If the *entire* behavior of a command, when run without any special
  options, is determined by the existence of 1 or more pkgfiles,
  or by the existence of a file or directory in a location in the
  tmpdir, it can be marked as such, which allows dh to automatically
  skip running it.  Please see "Optimization techniques" below.

- `pkgext($package)`

  Pass this command the name of a binary package, and it will return
  the name to prefix to files in `debian/` for this package. For the
  `$dh{MAINPACKAGE}`, it returns nothing (there is no prefix), for the other
  packages, it returns `package.`.

- `isnative($package)`

  Pass this command the name of a package, it returns 1 if the package
  is a native debian package.
  As a side effect, `$dh{VERSION}` is set to the version number of the
  package.

- `autoscript($package, $scriptname, $snippetname, $substparam)`

  Pass parameters:
  - binary package to be affected
  - script to add to
  - filename of snippet. For testing purposes, you can set the
    environment variable `DH_DATAFILES` containing a autoscripts
    directory, which can be used to shadow the snippets provided
    in `/usr/share/debhelper/autoscripts` (or to test newly added
    snippets).  
    Older versions of debhelper (<< 13.1~) do not support
    `DH_DATAFILES`.  If you need to support debhelper (<< 13.1~)
    then you can set `DH_AUTOSCRIPTDIR` to a directory containing
    the snippets instead (note it should point to the autoscripts
    directory unlike `DH_DATAFILES`).

  - (optional) A substitution parameter, which is one of 3 types:
    - sed commands to run on the snippet, e.g. `s/#PACKAGE#/$PACKAGE/`.  
      Note: Passed to the shell inside double quotes.
    - a perl sub to invoke with `$_` set to each line of the snippet
      in turn.
    - a hashref, where each key will substitute `#${key}#` with the
      value that `$key` points to.  [debhelper (>= 10.7)]

  This command automatically adds shell script snippets to a debian
  maintainer script (like the postinst or prerm).
  Note that in v6 mode and up, the snippets are added in reverse
  order for the removal scripts.

- `autotrigger($package, $trigger_type, $trigger_target)`

  This command automatically adds a trigger to the package.  The
  parameters:
  - binary package to be affected
  - the type of trigger (e.g. "activate-noawait")
  - the target (e.g. `ldconfig` or `/usr/share/foo`)

- `dirname($pathname)`

  Return directory part of pathname.

- `basename($pathname)`

  Return base of pathname,

- `addsubstvar($package, $substvar, $deppackage, $verinfo, $remove)`

  This function adds a dependency on some package to the specified
  substvar in a package's substvar's file. It needs all these
  parameters:
  - binary package that gets the item
  - name of the substvar to add the item to
  - the package that will be depended on
  - version info for the package (optional) (i.e. ">= 1.1")
  - if this last parameter is passed, the thing that would be added
    is removed instead. This can be useful to ensure that a debhelper
    command is idempotent. (However, we generally don't bother,
    and rely on the user calling `dh_prep`.) Note that without this
    parameter, if you call the function twice with the same values it
    will only add one item to the substvars file.

- `delsubstvar($package, $substvar)`

  This function removes the entire line for the substvar from the
  package's shlibs file.

- `excludefile($filename)`

  This function returns true if `-X` has been used to ask for the file
  to be excluded.

- `is_udeb($package)`

  Returns true if the package is marked as a udeb in the control
  file.

- `getpackages($type)`

  Returns a list of packages in the control file.
  Pass "arch" or "indep" to specify arch-dependent or
  -independent. If `$type` is omitted, returns all
  packages (including packages that are not built
  for this architecture). Pass "both" to get the union
  of "arch" and "indep" packages.  
  Note that "both" is *not* the same omitting the `$type` parameter.  
  As a side effect, populates `%package_arches` and `%package_types` with
  the types of all packages (not only those returned).

- `get_source_date_epoch()`

  Return the value of `$ENV{SOURCE_DATE_EPOCH}` if exists.
  Otherwise compute the value from the first changelog entry,
  use it to set the ENV variable and return it.

- `inhibit_log()`

  Prevent logging the program's successful finish to
  `debian/*debhelper.log`

  Since debhelper 12.9, this can be done by passing the `inhibit_log`
  option with a value of 1 to `init()` instead.  E.g.

      init('inhibit_log' => 1);

- `load_log($package, $hashref)`

  Loads the log file for the given package and returns a list of
  logged commands.
  (Passing a hashref also causes it to populate the hash.)

- `write_log($cmd, $package ...)`

  Writes the log files for the specified package(s), adding
  the cmd to the end.

- `restore_file_on_clean($file)`

  Store a copy of `$file`, which will be restored by `dh_clean`.
  The `$file` *must* be a relative path to the package root and
  *must* be a real regular file.  Dirs, devices and symlinks
  (and everything else) *cannot* be restored by this.
  If `$file` is passed multiple times (e.g. from different programs)
  only the first version is stored.
  CAVEAT: This *cannot* undo arbitrary "rm -fr"'ing.  The dir,
  which the `$file` is/was in, must be present when `dh_clean` is
  called.

  Note: This feature is also accessible via `dh_assistant restore-file-on-clean`
  since debhelper/13.12

- `make_symlink($src, $dest, $tmp)`

  Creates a Policy compliant system link called `$dest` pointing to
  `$src`. If `$tmp` is given, then `$tmp` will be prefixed to `$dest`
  when creating the actual symlink.

- `install_dh_config_file($src, $dest)`

  Installs `$src` into `$dest` using mode 0644.
  If compat is 9 (or later) and `$src` is executable, `$src` will
  be executed instead and its output will be used to generate the
  `$dest` file.

- `install_dir(@dirs)` / `mkdirs(@dirs)`

  Create the directories denoted by the paths in `@dirs` and all
  parent entries as well (as needed).  It uses mode 0755.
  If a directory listed in `@dirs` already exists, the function
  silently skips that directory (similar to `mkdir -p`).

  The `install_dir` function should be used for directories
  installed in a final package while `mkdirs` should be used
  for other directories.  The difference is related to whether
  the change will be shown via -v/--verbose or not.  The
  `mkdirs` function requires `debhelper (>= 13.11~)`.

- `install_file($src, $dest)`

  Installs `$src` into `$dest` with mode 0644.  The parent dir of
  `$dest` must exist (can be created with `install_dir`).
  This is intended for installing regular non-executable files.

- `install_prog($src, $dest)`

  Installs `$src` into `$dest` with mode 0755.  The parent dir of
  `$dest` must exist (can be created with `install_dir`).
  This is intended for installing scripts or binaries.

- `install_lib($src, $dest)`

  Installs a library at the path `$src` into `$dest`.  The parent
  dir of `$dest` must exist (can be created with `install_dir`).
  This is intended for installing libraries.

- `reset_perm_and_owner($mode, $path...)`

  Resets the ownership and mode (POSIX permissions) of `$path`
  This is useful for files created directly by the script, but
  it not necessary for files installed via the `install_*`
  functions.  
  The file owner and group is set to "root:root".  The change
  is only done on the exact paths listed (i.e. it is *not*
  recursive).  
  Mode should be passed as an integer (not a string).

- `open_gz($file)`

  Open `$file`, read from it as a gzip-compressed file and return
  the file handle.
  Depending on runtime features, it might be a pipe from an
  external process (which will die with a "SIGPIPE" if you
  do not consume all the input)

- `deprecated_functionality($warn_msg[, $rm_compat[, $rm_msg]])`

  Emit `$warn_msg` as a deprecation warning, or error out if `$rm_compat`
  is provided and equal to (or greater than) the active compat level.
  The `$rm_msg` parameter can be used to provide a custom error message
  in the latter case (if omitted, `$warn_msg` will be used in both cases).
  The function will provide a separate diagnostic about which compat
  level that will remove/removed the functionality if `$rm_compat` is
  given.

- `log_installed_files($package, @paths)`

  Creates a logfile (in `debian/.debhelper/generated`) for the helper's
  processing of `$package`, which installed the files listed in
  `@paths`. This logfile will later be used by the `dh_missing` helper.
  Paths should be relative to the package root (i.e. the directory
  containing `debian/`) and should not have superfluous segments
  (e.g. avoid `foo/../bar` or `foo/./bar`).
  If a directory is listed, it and all paths recursively beneath is
  also considered installed.

- `on_pkgs_in_parallel($code)` - prototype: (&)

  Short hand for `on_items_in_parallel` with `$dh{DOPACKAGES}` as
  as list of packages.

- `on_items_in_parallel($item_list_ref, $code)`

  Splits all the items in `$item_list_ref` into a number of groups
  based on the max parallel (as decided by `DEB_BUILD_OPTIONS`)
  A subprocess is forked for each group (minimum 1 process will be
  forked) and each subprocess will be given a group of items
  to process.  Each group is passed to the `$code` sub, which will
  then process it and return normally on success.
  Example:

      my @all_packages = getpackages();
      on_items_in_parallel(\@all_packages, sub {
      	for my $package (@_) {
      		my $tmp=tmpdir($package);
      		my $pkgfile = pkgfile($package, 'foo');
      		...;
      	}
      });
      my @work_list = compute_work_list();
      on_items_in_parallel(\@work_list, sub {
      	for my $item (@_) {
      		...;
      	}
      });

  If there is an error, which should stop the build, please invoke
  either `error()` or `error_exitcode`.  Alternatively, a trappable
  error (e.g. `die($msg)`) can also be used.

  Keep in mind that the sub will always be run in a subprocess,
  so it cannot update global state.

## Sequence Addons

The [dh(1)] command has a `--with <addon>` parameter that can be used to load
a sequence addon module named `Debian::Debhelper::Sequence::<addon>`.  
These modules can add/remove commands to the dh command sequences, by
calling some functions from `Dh_Lib`:

- `insert_before($existing_command, $new_command)`

  Insert `$new_command` in sequences before `$existing_command`

  Compatible with "arch-only"/"indep-only" modes if the command
  appears only in a compatible sequence.

- `insert_after($existing_command, $new_command)`

  Insert `$new_command` in sequences after `$existing_command`

  Compatible with "arch-only"/"indep-only" modes if the command
  appears only in a compatible sequence.

- `remove_command($existing_command)`

  Remove `$existing_command` from the list of commands to run
  in all sequences.

  Cannot be used in "arch-only"/"indep-only" mode.

- `add_command($new_command, $sequence)`

  Add `$new_command` to the beginning of the specified sequence.
  If the sequence does not exist, it will be created.

  Compatible with "arch-only"/"indep-only" modes if `$sequence`
  is an "-arch" or "-indep" sequence (respectively).

- `add_command_options($command, $opt1, $opt2, ...)`

  Append `$opt1`, `$opt2` etc. to the list of additional options which
  dh passes when running the specified `$command`. These options are
  not relayed to debhelper commands called via `$command` override.

  Cannot be used in "arch-only"/"indep-only" mode.

- `remove_command_options($command)`

  Clear all additional `$command` options previously added with
  `add_command_options()`.

  Cannot be used in "arch-only"/"indep-only" mode.

- `remove_command_options($command, $opt1, $opt2, ...)`

  Remove `$opt1`, `$opt2` etc. from the list of additional options which
  dh passes when running the specified `$command`.

  Cannot be used in "arch-only"/"indep-only" mode.

- `declare_command_obsolete([$error_compat, ]$command)`

  Declare `$command` as obsolete, which make dh warn about leftover
  override / hook targets.  Note that `$command` *MUST NOT* be present
  in the sequence!

  The `$error_compat` parameter defines the compat level where
  referencing this command via a hook target will become an error.
  This must be at least 13 (which is the default if omitted).
  Be careful with using already closed compat levels as error compat
  for new commands as it will cause FTBFS.

  Cannot be used in "arch-only"/"indep-only" mode.

## Optimization techniques

Most debhelper tools will have situations where they are not useful and can
be skipped.  To support this, dh will look for a "NOOP PROMISE" as a part of
a comment in the command before running it.  These promises have the form:

    # PROMISE: DH NOOP WITHOUT pkgfile-logged(pkgfileA)  pkgfile-logged(pkgfileB) tmp(need/this) cli-options()

The following keywords are defined:

- `pkgfile(X)`: The command might do something if `debian/X` (or `debian/<package>.X`)
  exist for any of the packages it will be run for. If the debhelper tool
  interacts with `dh_missing`, you always want to use `pkgfile-logged(X)` instead.

- `pkgfile-logged(X)`: Same as `pkgfile(X)` but it will also register which files
  it handles so `dh_missing` can see it.

- `tmp(X)`: The command might do something if `debian/<package>/X` exists.

- `cli-options(--foo|--bar)`: The command might do something if *either* `--foo`
  OR `--bar` are passed to the command.

- `cli-options(BUILDSYSTEM)`: The command is a build system command (`dh_auto_*`)
  and will react to standard build system command line options.

- `cli-options()`: Special variant of `cli-options()` to declare that command
  line options will not affect whether the tool will do something.  This enables
  dh to skip commands even when passed custom options.  Without an explicit
  `cli-option(...)` hint, dh will assume the command might react to it.

If the hint is present and ALL of the keywords imply that the command can be
skipped, dh will skip the command.

## Logging helpers and dh_missing

Since debhelper 10.3, debhelper has had a helper called `dh_missing`.  It
takes over the `--list-missing` and `--fail-missing` options from `dh_install`
and as the advantage that it can "see" what other helpers have installed.

Under the hood, this works by the helpers logging the source files
they (would) install to a hidden log file.  When `dh_missing` is called,
it reads all these log files to determine which files have would been
installed and compare them to what is present.

If you are writing a helper that need to integrate with `dh_missing`,
here is what you do:

### Dh_Lib-based helpers

- Replace `@{$dh{DOPACKAGES}}` with `getpackages()` and use
  `process_pkg($package)` to determine if the helper should actually
  install anything.
- Call `log_installed_files` at least once per package (even on the ones
  that are not to be acted on) with a list of source files that would be
  installed.
  - You can list entire directories even if there are files under
    it that are ignored.
  - Please call `log_installed_files` *even if* the list is empty for that
    packages.  This enables `dh_missing` to see that the helper has been run
    and nothing should be installed for that package.
  - Prefer calling `log_installed_files` *exactly once* per package as
    this is what it is optimized for.
- If your helper has a `PROMISE`, it must use `pkgfile-logged(<file>)`
  for its config files.  (See [#867246])
  - CAVEAT: This requires a dependency on "debhelper (>= 10.2.5)".  Prior
    to that version, debhelper will wrongly optimize your helper out.
- Consider using `dh_installman` or `dh_installexamples` as examples.

### Other helpers - via dh_assistant log-installed-files

This process requires debhelper/13.10 or later.

- The helper must compile a list of files it would have installed for
  each package (even packages that are not acted on).  The file list
  should be relative to the source package root (e.g.
  `debian/tmp/usr/bin/bar`).
  - This list can also contain directories.  They will be flagged as
    installed along with their content (recursively).
- Invoke `dh_assistant log-installed-files --on-behalf-of-cmd=${HELPER_NAME} -p${package} ${PATHS}`
  - Invoking `dh_assistant` when your tool has no paths to log is
    still recommended to let dh_missing that your tool had nothing
    to record.
  - Prefer calling `dh_assistant log-installed-files` *exactly once*
    per package per invocation of your tool as this is what it is
    optimized for.
- If your helper has a PROMISE, it must use `pkgfile-logged(<file>)`
  for its config files (see [#867246]).

### Other helpers - manually

- The helper must compile a list of files it would have installed for
  each package (even packages that are not acted on).  The file list
  should be relative to the source package root (e.g.
  `debian/tmp/usr/bin/bar`).
  - This list can also contain directories.  They will be flagged as
    installed along with their content (recursively).
- The helper must append to the file (create it if missing):
     `debian/.debhelper/generated/${package}/installed-by-${HELPER_NAME}`
  - Example: `debian/.debhelper/generated/lintian/installed-by-dh_install`
  - The file should be created even if it is empty.  This enables `dh_missing`
    to see that the helper has been run and nothing would be installed for
    that package.
- Please append to the file if it exists as the helper may be called multiple
  times (once with `-a` and once with `-i`).  It is completely fine if this
  leaves duplicate entries as dh_missing will deduplicate these.
- If your helper has a PROMISE, it must use `pkgfile-logged(<file>)`
  for its config files (see [#867246]).
  CAVEAT: This requires a dependency on "debhelper (>= 10.2.5)".  Prior
  to that version, debhelper will wrongly optimize your helper out.

## Buildsystem Classes

The `dh_auto_*` commands are frontends that use debhelper buildsystem
classes. These classes have names like `Debian::Debhelper::Buildsystem::foo`,
and are derived from `Debian::Debhelper::Buildsystem`, or other, related
classes.

A buildsystem class needs to inherit or define these methods: `DESCRIPTION`,
`check_auto_buildable`, `configure`, `build`, `test`, `install`, `clean`. See
the comments inside `Debian::Debhelper::Buildsystem` for details. Note that
this interface is still subject to change.

Note that third-party buildsystems will not automatically be used by
default.  The package maintainer will either have to explicitly enable
it via the `--buildsystem` parameter OR the build system should be
registered in debhelper.  The latter is currently needed to ensure a
stable and well-defined ordering of the build systems.

[dh(1)]: https://manpages.debian.org/dh.1 "dh - debhelper command sequencer"
[debhelper(7)]: https://manpages.debian.org/debhelper.7 "debhelper - the debhelper tool suite"
[#867246]: https://bugs.debian.org/867246 "dh_installman incorrectly optimized away when using --fail-missing and building arch-any packages only"

-- Joey Hess <joeyh@debian.org>
