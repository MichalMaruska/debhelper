#!/usr/bin/perl
#
# Library functions for debhelper programs, perl version.
#
# Joey Hess, GPL copyright 1997-2008.

package Debian::Debhelper::Dh_Lib;

use v5.28;
use warnings;
use utf8;

# Disable unicode_strings for now until a better solution for
# Debian#971362 comes around.
no feature 'unicode_strings';

use Errno qw(ENOENT);

use constant {
	# Lowest compat level supported
	'MIN_COMPAT_LEVEL' => 7,
	# Lowest compat level that does *not* cause deprecation
	# warnings
	'LOWEST_NON_DEPRECATED_COMPAT_LEVEL' => 10,
	# Lowest compat level to generate "debhelper-compat (= X)"
	# relations for.
	'LOWEST_VIRTUAL_DEBHELPER_COMPAT_LEVEL' => 9,
	# Highest compat level permitted
	'MAX_COMPAT_LEVEL' => 15,
	# Magic value for xargs
	'XARGS_INSERT_PARAMS_HERE' => \'<INSERT-HERE>', #'# Hi emacs.
	# Magic value for debhelper tools to request "current version"
	'DH_BUILTIN_VERSION' => \'<DH_LIB_VERSION>', #'# Hi emacs.
	# Default Package-Type / extension (must be aligned with dpkg)
	'DEFAULT_PACKAGE_TYPE' => 'deb',
};


# The Makefile changes this if debhelper is installed in a PREFIX.
my $prefix="/usr";
# The Makefile changes this during install to match the actual version.
use constant HIGHEST_STABLE_COMPAT_LEVEL => undef;

# Locations we search for data files by default
my @DATA_INC_PATH = (
	"${prefix}/share/debhelper",
);
# Enable the use of DH_DATAFILES for testing purposes.
unshift(@DATA_INC_PATH, split(':', $ENV{'DH_DATAFILES'})) if exists($ENV{'DH_DATAFILES'});

use constant {
	# Package-Type / extension for dbgsym packages
	# TODO: Find a way to determine this automatically from the vendor
	#  - blocked by Dpkg::Vendor having a rather high load time (for debhelper)
	'DBGSYM_PACKAGE_TYPE' => DEFAULT_PACKAGE_TYPE,
	# Lowest compat level supported that is not scheduled for removal.
	# - Set to MIN_COMPAT_LEVEL when there are no pending compat removals.
	'MIN_COMPAT_LEVEL_NOT_SCHEDULED_FOR_REMOVAL' => MIN_COMPAT_LEVEL,
};


# Internal constants used to define limits in variable expansions.
use constant {
	# How many expansions are permitted in total.
	_VAR_SUBST_EXPANSION_COUNT_LIMIT              => 50,
	# When recursion is enabled, how many times will we expand a pattern
	# on the same position in the string.
	_VAR_SUBST_SAME_POSITION_RECURSION_LIMIT      => 20,
	# Expansions are always allowed to grow up to this length regardless
	# of original input size (provided it does not trip another limit)
	_VAR_SUBST_EXPANSION_MIN_SUPPORTED_SIZE_LIMIT => 4096,
	# Factor input is allowed to grow before it triggers an error
	# (_VAR_SUBST_EXPANSION_MIN_SUPPORTED_SIZE_LIMIT overrules this for a
	#  given input if the max size limit computed with this factor is less
	#  than _VAR_SUBST_EXPANSION_MIN_SUPPORTED_SIZE_LIMIT)
	_VAR_SUBST_EXPANSION_DYNAMIC_EXPANSION_FACTOR_LIMIT => 3,
};


use Errno qw(ENOENT EXDEV);
use Exporter qw(import);
use File::Glob qw(bsd_glob GLOB_CSH GLOB_NOMAGIC GLOB_TILDE);
our (@EXPORT, %dh);
@EXPORT = (
	# debhelper basis functionality
qw(
	init
	%dh
	compat
),
	# External command tooling API
qw(
	doit
	doit_noerror
	qx_cmd
	xargs
	XARGS_INSERT_PARAMS_HERE
	print_and_doit
	print_and_doit_noerror

	complex_doit
	escape_shell
),
	# Logging/messaging/error handling
qw(
	error
	error_exitcode
	warning
	verbose_print
	nonquiet_print
),
	# Package related actions
qw(
	getpackages
	sourcepackage
	tmpdir
	dbgsym_tmpdir
	default_sourcedir
	pkgfile
	pkgext
	pkgfilename
	package_is_arch_all
	package_binary_arch
	package_declared_arch
	package_multiarch
	package_is_essential
	package_section
	package_arch
	package_type
	package_field
	process_pkg
	compute_doc_main_package
	isnative
	is_udeb
),
	# File/path related actions
qw(
	basename
	dirname
	mkdirs
	install_file
	install_prog
	install_lib
	install_dir
	install_dh_config_file
	make_symlink
	make_symlink_raw_target
	rename_path
	find_hardlinks
	rm_files
	excludefile
	is_so_or_exec_elf_file
	is_empty_dir
	reset_perm_and_owner
	log_installed_files

	filearray
	filedoublearray
	glob_expand
	glob_expand_error_handler_reject
	glob_expand_error_handler_warn_and_discard
	glob_expand_error_handler_silently_ignore
	glob_expand_error_handler_reject_nomagic_warn_discard
),
	# Generate triggers, substvars, maintscripts, build-time temporary files
qw(
	autoscript
	autotrigger
	addsubstvar
	delsubstvar
	ensure_substvars_are_present

	generated_file
	restore_file_on_clean
),
	# Split tasks among different cores
qw(
	on_pkgs_in_parallel
	on_items_in_parallel
	on_selected_pkgs_in_parallel
),
	# R³ framework
qw(
	should_use_root
	gain_root_cmd

),
	# Architecture, cross-tooling, build options and profiles
qw(
	dpkg_architecture_value
	hostarch
	cross_command
	is_cross_compiling
	is_build_profile_active
	get_buildoption
	perl_cross_incdir
),
	# Other
qw(
	open_gz
	get_source_date_epoch
	get_non_binnmu_date_epoch
	deprecated_functionality
),
	# Special-case functionality (e.g. tool specific), debhelper(-core) functionality and deprecated functions
qw(
	inhibit_log
	load_log
	write_log
	commit_override_log
	debhelper_script_subst
	debhelper_script_per_package_subst
	is_make_jobserver_unavailable
	clean_jobserver_makeflags
	set_buildflags
	DEFAULT_PACKAGE_TYPE
	DBGSYM_PACKAGE_TYPE
	DH_BUILTIN_VERSION
	is_known_package
	assert_opt_is_known_package
	restore_all_files

	buildarch
));

my $MAX_PROCS = get_buildoption("parallel") || 1;
my $DH_TOOL_VERSION;

our $PKGNAME_REGEX = qr/[a-z0-9][-+\.a-z0-9]+/o;
our $PKGVERSION_REGEX = qr/
                 (?: \d+ : )?                # Optional epoch
                 [0-9][0-9A-Za-z.+:~]*       # Upstream version (with no hyphens)
                 (?: - [0-9A-Za-z.+:~]+ )*   # Optional debian revision (+ upstreams versions with hyphens)
                          /xoa;
our $MAINTSCRIPT_TOKEN_REGEX = qr/[A-Za-z0-9_.+]+/o;
our $TOOL_NAME = basename($0);

# From Policy 5.1:
#
#  The field name is composed of US-ASCII characters excluding control
#  characters, space, and colon (i.e., characters in the ranges U+0021
#  (!) through U+0039 (9), and U+003B (;) through U+007E (~),
#  inclusive). Field names must not begin with the comment character
#  (U+0023 #), nor with the hyphen character (U+002D -).
our $DEB822_FIELD_REGEX = qr/
	    [\x21\x22\x24-\x2C\x2F-\x39\x3B-\x7F]  # First character
	    [\x21-\x39\x3B-\x7F]*                  # Subsequent characters (if any)
    /xoa;

our $PARSE_DH_SEQUENCE_INFO = 0;
# Safety valve for `dh_assistant`. Not intended for anyone else.
our $ALLOW_UNSAFE_EXECUTION = 1;

# We need logging in compat 9 or in override/hook targets (for --remaining-packages to work)
# - This option is a global toggle to disable logs for special commands (e.g. dh or dh_clean)
# It is initialized during "init".  This implies that commands that never calls init are
# not dh_* commands or do not need the log
my $write_log = undef;

sub init {
	my %params=@_;

	if ($params{internal_parse_dh_sequence_info}) {
		$PARSE_DH_SEQUENCE_INFO = 1;
	}

	# Check if we can by-pass the expensive Getopt::Long by optimising for the
	# common case of "-a" or "-i"
	if (scalar(@ARGV) == 1 && ($ARGV[0] eq '-a' || $ARGV[0] eq '-i') &&
		! (defined $ENV{DH_OPTIONS} && length $ENV{DH_OPTIONS}) &&
		! (defined $ENV{DH_INTERNAL_OPTIONS} && length $ENV{DH_INTERNAL_OPTIONS})) {

		# Single -i or -a as dh does it.
		if ($ARGV[0] eq '-i') {
			push(@{$dh{DOPACKAGES}}, getpackages('indep'));
			$dh{DOINDEP} = 1;
		} else {
			push(@{$dh{DOPACKAGES}}, getpackages('arch'));
			$dh{DOARCH} = 1;
		}

		if (! @{$dh{DOPACKAGES}}) {
			if (! $dh{BLOCK_NOOP_WARNINGS}) {
				warning("You asked that all arch in(dep) packages be built, but there are none of that type.");
			}
			exit(0);
		}
		# Clear @ARGV so we do not hit the expensive case below
		@ARGV = ();
	}

	# Check to see if an option line starts with a dash,
	# or DH_OPTIONS is set.
	# If so, we need to pass this off to the resource intensive 
	# Getopt::Long, which I'd prefer to avoid loading at all if possible.
	if ((defined $ENV{DH_OPTIONS} && length $ENV{DH_OPTIONS}) ||
 	    (defined $ENV{DH_INTERNAL_OPTIONS} && length $ENV{DH_INTERNAL_OPTIONS}) ||
	    grep /^-/, @ARGV) {
		eval { require Debian::Debhelper::Dh_Getopt; };
		error($@) if $@;
		Debian::Debhelper::Dh_Getopt::parseopts(%params);
	}

	# Another way to set excludes.
	if (exists $ENV{DH_ALWAYS_EXCLUDE} && length $ENV{DH_ALWAYS_EXCLUDE}) {
		push @{$dh{EXCLUDE}}, split(":", $ENV{DH_ALWAYS_EXCLUDE});
	}
	
	# Generate EXCLUDE_FIND.
	if ($dh{EXCLUDE}) {
		$dh{EXCLUDE_FIND}='';
		foreach (@{$dh{EXCLUDE}}) {
			my $x=$_;
			$x=escape_shell($x);
			$x=~s/\./\\\\./g;
			$dh{EXCLUDE_FIND}.="-regex .\\*$x.\\* -or ";
		}
		$dh{EXCLUDE_FIND}=~s/ -or $//;
	}
	
	# Check to see if DH_VERBOSE environment variable was set, if so,
	# make sure verbose is on. Otherwise, check DH_QUIET.
	if (defined $ENV{DH_VERBOSE} && $ENV{DH_VERBOSE} ne "") {
		$dh{VERBOSE}=1;
	} elsif (defined $ENV{DH_QUIET} && $ENV{DH_QUIET} ne "" || get_buildoption("terse")) {
		$dh{QUIET}=1;
	}

	# Check to see if DH_NO_ACT environment variable was set, if so, 
	# make sure no act mode is on.
	if (defined $ENV{DH_NO_ACT} && $ENV{DH_NO_ACT} ne "") {
		$dh{NO_ACT}=1;
	}

	# Get the name of the main binary package (first one listed in
	# debian/control). Only if the main package was not set on the
	# command line.
	if (! exists $dh{MAINPACKAGE} || ! defined $dh{MAINPACKAGE}) {
		my @allpackages=getpackages();
		$dh{MAINPACKAGE}=$allpackages[0];
	}

	# Check if packages to build have been specified, if not, fall back to
	# the default, building all relevant packages.
	if (! defined $dh{DOPACKAGES} || ! @{$dh{DOPACKAGES}}) {
		push @{$dh{DOPACKAGES}}, getpackages('both');
	}

	# Check to see if -P was specified. If so, we can only act on a single
	# package.
	if ($dh{TMPDIR} && $#{$dh{DOPACKAGES}} > 0) {
		error("-P was specified, but multiple packages would be acted on (".join(",",@{$dh{DOPACKAGES}}).").");
	}

	# Figure out which package is the first one we were instructed to build.
	# This package gets special treatement: files and directories specified on
	# the command line may affect it.
	$dh{FIRSTPACKAGE}=${$dh{DOPACKAGES}}[0];

	# If no error handling function was specified, just propagate
	# errors out.
	if (! exists $dh{ERROR_HANDLER} || ! defined $dh{ERROR_HANDLER}) {
		$dh{ERROR_HANDLER}='exit 1';
	}

	$dh{U_PARAMS} //= [];

	if ($params{'inhibit_log'}) {
		$write_log = 0;
	} else {
		# Only initialize if unset (i.e. avoid overriding an early call
		# to inhibit_log()
		$write_log //= 1;
	}
}

# Ensure the log is written if requested but only if the command was
# successful.
sub END {
	return if $? != 0 or not $write_log;
	# If there is no 'debian/control', then we are not being run from
	# a package directory and then the write_log will not do what we
	# expect.
	return if not -f 'debian/control';
	if (compat(9, 1) || $ENV{DH_INTERNAL_OVERRIDE}) {
		write_log($TOOL_NAME, @{$dh{DOPACKAGES}});
	}
}

sub logfile {
	my $package=shift;
	my $ext=pkgext($package);
	return "debian/${ext}debhelper.log"
}

sub load_log {
	my ($package, $db)=@_;

	my @log;
	open(LOG, "<", logfile($package)) || return;
	while (<LOG>) {
		chomp;
		my $command = $_;
		push @log, $command;
		$db->{$package}{$command}=1 if defined $db;
	}
	close LOG;
	return @log;
}

sub write_log {
	my $cmd=shift;
	my @packages=@_;

	return if $dh{NO_ACT};

	foreach my $package (@packages) {
		my $log = logfile($package);
		open(LOG, ">>", $log) || error("failed to write to ${log}: $!");
		print LOG $cmd."\n";
		close LOG;
	}
}

sub commit_override_log {
	my @packages=@_;

	return if $dh{NO_ACT};

	foreach my $package (@packages) {
		my @log = load_log($package);
		my $log = logfile($package);
		open(LOG, ">", $log) || error("failed to write to ${log}: $!");
		print LOG $_."\n" foreach @log;
		close LOG;
	}
}

sub inhibit_log {
	$write_log=0;
}

# Pass it an array containing the arguments of a shell command like would
# be run by exec(). It turns that into a line like you might enter at the
# shell, escaping metacharacters and quoting arguments that contain spaces.
sub escape_shell {
	my @args=@_;
	my @ret;
	foreach my $word (@args) {
		if ($word=~/\s/) {
			# Escape only a few things since it will be quoted.
			# Note we use double quotes because you cannot
			# escape ' in single quotes, while " can be escaped
			# in double.
			# This does make -V"foo bar" turn into "-Vfoo bar",
			# but that will be parsed identically by the shell
			# anyway..
			$word=~s/([\n`\$"\\])/\\$1/g;
			push @ret, "\"$word\"";
		}
		else {
			# This list is from _Unix in a Nutshell_. (except '#')
			$word=~s/([\s!"\$()*+#;<>?@\[\]\\`|~])/\\$1/g;
			push @ret,$word;
		}
	}
	return join(' ', @ret);
}

# Run a command, and display the command to stdout if verbose mode is on.
# Throws error if command exits nonzero.
#
# All commands that modify files in $TMP should be run via this
# function.
#
# Note that this cannot handle complex commands, especially anything
# involving redirection. Use complex_doit instead.
sub doit {
	doit_noerror(@_) || error_exitcode(_format_cmdline(@_));
}

sub doit_noerror {
	verbose_print(_format_cmdline(@_)) if $dh{VERBOSE};

	goto \&_doit;
}

sub print_and_doit {
	print_and_doit_noerror(@_) || error_exitcode(_format_cmdline(@_));
}

sub print_and_doit_noerror {
	nonquiet_print(_format_cmdline(@_));

	goto \&_doit;
}

sub _post_fork_setup_and_exec {
	my ($close_stdin, $options, @cmd) = @_;
	if (defined($options)) {
		if (defined(my $dir = $options->{chdir})) {
			if ($dir ne '.') {
				chdir($dir) or error("chdir(\"${dir}\") failed: $!");
			}
		}
		if ($close_stdin) {
			open(STDIN, '<', '/dev/null') or error("redirect STDIN failed: $!");
		}
		if (defined(my $output = $options->{stdout})) {
			open(STDOUT, '>', $output) or error("redirect STDOUT failed: $!");
		}
		if (defined(my $update_env = $options->{update_env})) {
			while (my ($k, $v) = each(%{$update_env})) {
				if (defined($v)) {
					$ENV{$k} = $v;
				} else {
					delete($ENV{$k});
				}
			}
		}
	}
	# Force execvp call to avoid shell.  Apparently, even exec can
	# involve a shell if you don't do this.
	exec { $cmd[0] } @cmd or error('exec (for cmd: ' . escape_shell(@cmd) . ") failed: $!");
}

sub _doit {
	my (@cmd) = @_;
	my $options = ref($cmd[0]) ? shift(@cmd) : undef;
	# In compat <= 11, we warn, in compat 12 we assume people know what they are doing.
	if (not defined($options) and @cmd == 1 and compat(12) and $cmd[0] =~ m/[\s<&>|;]/) {
		deprecated_functionality('doit() + doit_*() calls will no longer spawn a shell in compat 12 for single string arguments (please use complex_doit instead)',
								 12);
		return 1 if $dh{NO_ACT};
		return system(@cmd) == 0;
	}
	return 1 if $dh{NO_ACT};
	my $pid = fork() // error("fork(): $!");
	if (not $pid) {
		_post_fork_setup_and_exec(1, $options, @cmd) // error("Assertion error: sub should not return!");
	}
	return waitpid($pid, 0) == $pid && $? == 0;
}

sub _format_cmdline {
	my (@cmd) = @_;
	my $options = ref($cmd[0]) ? shift(@cmd) : {};
	my $cmd_line = escape_shell(@cmd);
	if (defined(my $update_env = $options->{update_env})) {
		my $need_env = 0;
		my @params;
		for my $key (sort(keys(%{$update_env}))) {
			my $value = $update_env->{$key};
			if (defined($value)) {
				my $quoted_key = escape_shell($key);
				push(@params, join('=', $quoted_key, escape_shell($value)));
				# shell does not like: "FU BAR"=1 cmd
				# if the ENV key has weird symbols, the best bet is to use env
				$need_env = 1 if $quoted_key ne $key;
			} else {
				$need_env = 1;
				push(@params, escape_shell("--unset=${key}"));
			}
		}
		unshift(@params, 'env', '--') if $need_env;
		$cmd_line = join(' ', @params, $cmd_line);
	}
	if (defined(my $dir = $options->{chdir})) {
		$cmd_line = join(' ', 'cd', escape_shell($dir), '&&', $cmd_line) if $dir ne '.';
	}
	if (defined(my $output = $options->{stdout})) {
		$cmd_line .= ' > ' . escape_shell($output);
	}
	return $cmd_line;
}

sub qx_cmd {
	my (@cmd) = @_;
	my $options = ref($cmd[0]) ? shift(@cmd) : undef;
	my ($output, @output);
	my $pid = open(my $fd, '-|') // error('fork (for cmd: ' . escape_shell(@cmd) . ") failed: $!");
	if ($pid == 0) {
		_post_fork_setup_and_exec(0, $options, @cmd) // error("Assertion error: sub should not return!");
	}
	if (wantarray) {
		@output = <$fd>;
	} else {
		local $/ = undef;
		$output = <$fd>;
	}
	if (not close($fd)) {
		error("close pipe failed: $!") if $!;
		error_exitcode(escape_shell(@cmd));
	}
	return @output if wantarray;
	return $output;
}

# Run a command and display the command to stdout if verbose mode is on.
# Use doit() if you can, instead of this function, because this function
# forks a shell. However, this function can handle more complicated stuff
# like redirection.
sub complex_doit {
	verbose_print(join(" ",@_));
	
	if (! $dh{NO_ACT}) {
		# The join makes system get a scalar so it forks off a shell.
		system(join(" ", @_)) == 0 || error_exitcode(join(" ", @_))
	}			
}


sub error_exitcode {
	my $command=shift;
	if ($? == -1) {
		error("$command failed to execute: $!");
	}
	elsif ($? & 127) {
		error("$command died with signal ".($? & 127));
	}
	elsif ($?) {
		error("$command returned exit code ".($? >> 8));
	}
	else {
		warning("This tool claimed that $command have failed, but it");
		warning("appears to have returned 0.");
		error("Probably a bug in this tool is hiding the actual problem.");
	}
}

# Some shortcut functions for installing files and dirs to always
# have the same owner and mode
# install_file - installs a non-executable
# install_prog - installs an executable
# install_lib  - installs a shared library (some systems may need x-bit, others don't)
# install_dir  - installs a directory
{
	my $_loaded = 0;
	sub install_file {
		unshift(@_, 0644);
		goto \&_install_file_to_path;
	}

	sub install_prog {
		unshift(@_, 0755);
		goto \&_install_file_to_path;
	}
	sub install_lib {
		unshift(@_, 0644);
		goto \&_install_file_to_path;
	}

	sub _install_file_to_path {
		my ($mode, $source, $dest) = @_;
		if (not $_loaded) {
			$_loaded++;
			require File::Copy;
		}
		verbose_print(sprintf('install -p -m%04o %s', $mode, escape_shell($source, $dest)))
			if $dh{VERBOSE};
		return 1 if $dh{NO_ACT};
		# "install -p -mXXXX foo bar" silently discards broken
		# symlinks to install the file in place.  File::Copy does not,
		# so emulate it manually.  (#868204)
		if ( -l $dest and not -e $dest and not unlink($dest) and $! != ENOENT) {
			error("unlink $dest failed: $!");
		}
		File::Copy::copy($source, $dest) or error("copy($source, $dest): $!");
		chmod($mode, $dest) or error("chmod($mode, $dest): $!");
		my (@stat) = stat($source);
		error("stat($source): $!") if not @stat;
		utime($stat[8], $stat[9], $dest)
			or error(sprintf("utime(%d, %d, %s): $!", $stat[8] , $stat[9], $dest));
		return 1;
	}
}


sub _mkdirs {
	my ($log, @dirs) = @_;
	return if not @dirs;
	if ($log && $dh{VERBOSE}) {
		verbose_print(sprintf('install -m0755 -d %s', escape_shell(@dirs)));
	}
	return 1 if $dh{NO_ACT};
	state $_loaded;
	if (not $_loaded) {
		$_loaded++;
		require File::Path;
	}
	my %opts = (
		# install -d uses 0755 (no umask), make_path uses 0777 (& umask) by default.
		# Since we claim to run install -d, then ensure the mode is correct.
		'chmod' => 0755,
	);
	eval {
		File::Path::make_path(@dirs, \%opts);
	};
	if (my $err = "$@") {
		$err =~ s/\s+at\s+\S+\s+line\s+\d+\.?\n//;
		error($err);
	}
	return;
}

sub mkdirs {
	my @to_create = grep { not -d $_ } @_;
	return _mkdirs(0, @to_create);
}

sub install_dir {
	my @dirs = @_;
	return _mkdirs(1, @dirs);
}

sub rename_path {
	my ($source, $dest) = @_;

	if ($dh{VERBOSE}) {
		my $files = escape_shell($source, $dest);
		verbose_print("mv $files");
	}
	return 1 if $dh{NO_ACT};
	if (not rename($source, $dest)) {
		my $ok = 0;
		if ($! == EXDEV) {
			# Replay with a fork+exec to handle crossing two mount
			# points (See #897569)
			$ok = _doit('mv', $source, $dest);
		}
		if (not $ok) {
			my $files = escape_shell($source, $dest);
			error("mv $files: $!");
		}
	}
	return 1;
}

sub reset_perm_and_owner {
	my ($mode, @paths) = @_;
	my $use_root = should_use_root();
	if ($dh{VERBOSE}) {
		verbose_print(sprintf('chmod %#o -- %s', $mode, escape_shell(@paths)));
		verbose_print(sprintf('chown 0:0 -- %s', escape_shell(@paths))) if $use_root;
	}
	return if $dh{NO_ACT};
	for my $path (@paths) {
		chmod($mode, $path) or error(sprintf('chmod(%#o, %s): %s', $mode, $path, $!));
		if ($use_root) {
			chown(0, 0, $path) or error("chown(0, 0, $path): $!");
		}
	}
}

# Run a command that may have a huge number of arguments, like xargs does.
# Pass in a reference to an array containing the arguments, and then other
# parameters that are the command and any parameters that should be passed to
# it each time.
sub xargs {
	my ($args, @static_args) = @_;

        # The kernel can accept command lines up to 20k worth of characters.
	my $command_max=20000; # LINUX SPECIFIC!!
			# (And obsolete; it's bigger now.)
			# I could use POSIX::ARG_MAX, but that would be slow.

	# Figure out length of static portion of command.
	my $static_length=0;
	my $subst_index = -1;
	for my $i (0..$#static_args) {
		my $arg = $static_args[$i];
		if ($arg eq XARGS_INSERT_PARAMS_HERE) {
			error("Only one insertion place supported in xargs, got command: @static_args") if $subst_index > -1;
			$subst_index = $i;
			next;
		}
		$static_length+=length($arg)+1;
	}
	
	my @collect=();
	my $length=$static_length;
	foreach (@$args) {
		if (length($_) + 1 + $static_length > $command_max) {
			error("This command is greater than the maximum command size allowed by the kernel, and cannot be split up further. What on earth are you doing? \"@_ $_\"");
		}
		$length+=length($_) + 1;
		if ($length < $command_max) {
			push @collect, $_;
		}
		else {
			if ($#collect > -1) {
				if ($subst_index < 0) {
					doit(@static_args, @collect);
				} else {
					my @cmd = @static_args;
					splice(@cmd, $subst_index, 1, @collect);
					doit(@cmd);
				}
			}
			@collect=($_);
			$length=$static_length + length($_) + 1;
		}
	}
	if ($#collect > -1) {
		if ($subst_index < 0) {
			doit(@static_args, @collect);
		} else {
			my @cmd = @static_args;
			splice(@cmd, $subst_index, 1, @collect);
			doit(@cmd);
		}
	}
}

# Print something if the verbose flag is on.
sub verbose_print {
	my $message=shift;
	
	if ($dh{VERBOSE}) {
		print "\t$message\n";
	}
}

# Print something unless the quiet flag is on
sub nonquiet_print {
	my $message=shift;

	if (!$dh{QUIET}) {
		if (defined($message)) {
			print "\t$message\n";
		} else {
			print "\n";
		}
	}
}

sub _color {
	my ($msg, $color) = @_;
	state $_use_color;
	if (not defined($_use_color)) {
		# This part is basically Dpkg::ErrorHandling::setup_color over again
		# with some tweaks.
		# (but the module uses Dpkg + Dpkg::Gettext, so it is very expensive
		# to load)
		my $mode = $ENV{'DH_COLORS'} // $ENV{'DPKG_COLORS'};
		# Support NO_COLOR (https://no-color.org/)
		$mode //= exists($ENV{'NO_COLOR'}) ? 'never' : 'auto';

		# Initialize with no color, so we are guaranteed to only do this once.
		$_use_color = 0;
		if ($mode eq 'auto') {
			$_use_color = 1 if -t *STDOUT or -t *STDERR;
		} elsif ($mode eq 'always') {
			$_use_color = 1;
		}

		eval {
			require Term::ANSIColor if $_use_color;
		};
		if ($@) {
			# In case of errors, skip colors.
			$_use_color = 0;
		}
	}
	if ($_use_color) {
		local $ENV{'NO_COLOR'} = undef;
		$msg = Term::ANSIColor::colored($msg, $color);
	}
	return $msg;
}

# Output an error message and die (can be caught).
sub error {
	my ($message) = @_;
	# ensure the error code is well defined.
	$! = 255;
	die(_color($TOOL_NAME, 'bold') . ': ' . _color('error', 'bold red') . ": $message\n");
}

# Output a warning.
sub warning {
	my ($message) = @_;
	$message //= '';

	print STDERR _color($TOOL_NAME, 'bold') . ': ' . _color('warning', 'bold yellow') . ": $message\n";
}

# Returns the basename of the argument passed to it.
sub basename {
	my $fn=shift;

	$fn=~s/\/$//g; # ignore trailing slashes
	$fn=~s:^.*/(.*?)$:$1:;
	return $fn;
}

# Returns the directory name of the argument passed to it.
sub dirname {
	my $fn=shift;
	
	$fn=~s/\/$//g; # ignore trailing slashes
	$fn=~s:^(.*)/.*?$:$1:;
	return $fn;
}

# Pass in a number, will return true iff the current compatibility level
# is less than or equal to that number.
my ($compat_from_bd, $compat_from_dctrl);
{
	my $check_pending_removals = get_buildoption('dherroron', '') eq 'obsolete-compat-levels' ? 1 : 0;
	my $warned_compat = $ENV{DH_INTERNAL_TESTSUITE_SILENT_WARNINGS} ? 1 : 0;
	my $declared_compat;
	my $delared_compat_source;
	my $c;

	# Used mainly for testing
	sub resetcompat {
		undef $c;
		undef $compat_from_bd;
		undef $compat_from_dctrl;
	}

	sub _load_compat_info {
		my ($nowarn) = @_;

		getpackages() if not defined($compat_from_bd);

		$c=1;
		if (-e 'debian/compat') {
			open(my $compat_in, '<', "debian/compat") || error "debian/compat: $!";
			my $l=<$compat_in>;
			close($compat_in);
			if (! defined $l || ! length $l) {
				error("debian/compat must contain a positive number (found an empty first line)");
			}
			else {
				chomp $l;
				my $new_compat = $l;
				$new_compat =~ s/^\s*+//;
				$new_compat =~ s/\s*+$//;
				if ($new_compat !~ m/^\d+$/) {
					error("debian/compat must contain a positive number (found: \"${new_compat}\")");
				}
				if ($compat_from_bd != -1 or $compat_from_dctrl != -1) {
					warning("Please specify the debhelper compat level exactly once.");
					warning(" * debian/compat requests compat ${new_compat}.");
					warning(" * debian/control requests compat ${compat_from_bd} via \"debhelper-compat (= ${compat_from_bd})\"")
						if $compat_from_bd > -1;
					warning(" * debian/control requests compat ${compat_from_dctrl} via \"X-DH-Compat: ${compat_from_dctrl}\"")
						if $compat_from_dctrl > -1;
					warning();
					warning("Hint: If you just added a build-dependency on debhelper-compat, then please remember to remove debian/compat")
						if $compat_from_bd > -1;
					warning("Hint: If you just added a X-DH-Compat field, then please remember to remove debian/compat")
						if $compat_from_dctrl > -1;
					warning();
					error("debhelper compat level specified both in debian/compat and in debian/control");
				}
				$c = $new_compat;
			}
			if ($c >= 15 or (HIGHEST_STABLE_COMPAT_LEVEL//0) > 13) {
				error("Sorry, debian/compat is no longer a supported source for the debhelper compat level."
				 . " Please add a Build-Depends on `debhelper-compat (= C)` or add `X-DH-Compat: C` to the source stanza"
				 . " of d/control and remove debian/compat.");
			}
			if ($c >= 13 and not $nowarn) {
				warning("Use of debian/compat is deprecated and will be removed in debhelper (>= 14~).")
			}
			$delared_compat_source = 'debian/compat';
		} elsif ($compat_from_bd != -1) {
			$c = $compat_from_bd;
			$delared_compat_source = "Build-Depends: debhelper-compat (= $c)";
		} elsif ($compat_from_dctrl != -1) {
			$c = $compat_from_dctrl;
			$delared_compat_source = "X-DH-Compat: $c";
		} elsif (not $nowarn) {
			# d/compat deliberately omitted since we do not want to recommend users to it.
			error("Please specify the compatibility level in debian/control. Such as, via Build-Depends: debhelper-compat (= X)");
		}

		$declared_compat = int($c);

		if (defined $ENV{DH_COMPAT}) {
			my $override = $ENV{DH_COMPAT};
			error("The environment variable DH_COMPAT must be a positive integer")
				if $override ne q{} and $override !~ m/^\d+$/;
			$c=int($ENV{DH_COMPAT}) if $override ne q{};
		}
	}

	sub get_compat_info {
		if (not $c) {
			_load_compat_info(1);
		}
		return ($c, $declared_compat, $delared_compat_source);
	}

	sub compat {
		my ($num, $nowarn) = @_;

		if (not $c) {
			_load_compat_info($nowarn);
		}

		if (not $nowarn) {
			if ($c < MIN_COMPAT_LEVEL) {
				error("Compatibility levels before ${\MIN_COMPAT_LEVEL} are no longer supported (level $c requested)");
			}

			if ($check_pending_removals and $c < MIN_COMPAT_LEVEL_NOT_SCHEDULED_FOR_REMOVAL) {
				my $v = MIN_COMPAT_LEVEL_NOT_SCHEDULED_FOR_REMOVAL;
				error("Compatibility levels before ${v} are scheduled for removal and DH_COMPAT_ERROR_ON_PENDING_REMOVAL was set (level $c requested)");
			}

			if ($c < LOWEST_NON_DEPRECATED_COMPAT_LEVEL && ! $warned_compat) {
				warning("Compatibility levels before ${\LOWEST_NON_DEPRECATED_COMPAT_LEVEL} are deprecated (level $c in use)");
				$warned_compat=1;
			}
	
			if ($c > MAX_COMPAT_LEVEL) {
				error("Sorry, but ${\MAX_COMPAT_LEVEL} is the highest compatibility level supported by this debhelper.");
			}
		}

		return ($c <= $num);
	}
}

# Pass it a name of a binary package, it returns the name of the tmp dir to
# use, for that package.
sub tmpdir {
	my $package=shift;

	if ($dh{TMPDIR}) {
		return $dh{TMPDIR};
	}
	else {
		return "debian/$package";
	}
}

# Pass it a name of a binary package, it returns the name of the staging dir to
# use, for that package.  (Usually debian/tmp)
sub default_sourcedir {
	my ($package) = @_;

	return 'debian/tmp';
}

# Pass this the name of a binary package, and the name of the file wanted
# for the package, and it will return the actual existing filename to use.
#
# It tries several filenames:
#   * debian/package.filename.hostarch
#   * debian/package.filename.hostos
#   * debian/package.filename
#   * debian/filename (if the package is the main package and compat < 15)
# If --name was specified then the files
# must have the name after the package name:
#   * debian/package.name.filename.hostarch
#   * debian/package.name.filename.hostos
#   * debian/package.name.filename
#   * debian/name.filename (if the package is the main package and compat < 15)

{
	my %_check_expensive;

	sub pkgfile {
		# NB: $nameless_variant_handling is an implementation-detail; third-party packages
		# should not rely on it.
		my ($opts, $package, $filename);
		my ($nameless_variant_handling, $named, $support_architecture_restriction, $is_bulk_check);

		# !!NOT A PART OF THE PUBLIC API!!
		# Bulk test used by dh to speed up the can_skip check.   It
		# is NOT useful for finding the most precise pkgfile.

		if (ref($_[0]) eq 'HASH') {
			($opts, $package, $filename) = @_;
			$is_bulk_check = ref($package) eq 'ARRAY';
			if ($is_bulk_check) {
				# If `dh` does not have declarative hints to go by, then it must assume all
				# variants are possible
				$named = 1;
				$support_architecture_restriction = 1;
			}

			$nameless_variant_handling = $opts->{'internal-nameless-variant-handling'}
				if exists($opts->{'internal-nameless-variant-handling'});
			$named = $opts->{'named'} if exists($opts->{'named'});
			$support_architecture_restriction = $opts->{'support-architecture-restriction'}
				if exists($opts->{'support-architecture-restriction'});
		} else {
			($package, $filename) = @_;

			$is_bulk_check = ref($package) eq 'ARRAY';
			if ($is_bulk_check) {
				# If `dh` does not have declarative hints to go by, then it must assume all
				# variants are possible
				$named = 1;
				$support_architecture_restriction = 1;
			}
		}

		if (compat(13)) {
			# Before compat 14, these were unconditionally on.
			$named = 1;
			$support_architecture_restriction = 1;
		}

		my (@try, $check_expensive);

		if (not exists($_check_expensive{$filename})) {
			my @f = grep {
				!/\.debhelper$/
			} bsd_glob("debian/*.$filename.*", GLOB_CSH & ~(GLOB_NOMAGIC|GLOB_TILDE));
			if (not @f) {
				$check_expensive = 0;
			} else {
				$check_expensive = 1;
			}
			$_check_expensive{$filename} = $check_expensive;
		} else {
			$check_expensive = $_check_expensive{$filename};
		}

		# Rewrite $filename after the check_expensive globbing above
		# as $dh{NAME} is used as a prefix (so the glob above will
		# cover it).
		#
		# In practise, it should not matter as NAME is ether set
		# globally or not.  But if someone is being "clever" then the
		# cache is reusable and for the general/normal case, it has no
		# adverse effects.
		if (defined $dh{NAME} and $opts->{'named'}) {
			$filename="$dh{NAME}.$filename";
		}

		if ($is_bulk_check) {
			# !!NOT A PART OF THE PUBLIC API!!
			# Bulk test used by dh to speed up the can_skip check.   It
			# is NOT useful for finding the most precise pkgfile.
			push(@try, "debian/$filename");
			for my $pkg (@{$package}) {
				push(@try, "debian/${pkg}.${filename}");
				if ($check_expensive) {
					my $cross_type = uc(package_cross_type($pkg));
					push(@try,
						 "debian/${pkg}.${filename}.".dpkg_architecture_value("DEB_${cross_type}_ARCH"),
						 "debian/${pkg}.${filename}.".dpkg_architecture_value("DEB_${cross_type}_ARCH_OS"),
					);
				}
			}
		} else {
			# Avoid checking for hostarch+hostos unless we have reason
			# to believe that they exist.
			if ($check_expensive and $opts->{'support-architecture-restriction'}) {
				my $cross_type = uc(package_cross_type($package));
				push(@try,
					 "debian/${package}.${filename}.".dpkg_architecture_value("DEB_${cross_type}_ARCH"),
					 "debian/${package}.${filename}.".dpkg_architecture_value("DEB_${cross_type}_ARCH_OS"),
					);
			}
			push(@try, "debian/$package.$filename");
			my $nameless_variant = "debian/$filename";
			if (defined $dh{NAME} and not compat(13) and -f $nameless_variant) {
				warning('The use of prefix-less debhelper config files with --name is deprecated.');
				warning("Please rename \"${nameless_variant}\" to \"debian/$dh{MAINPACKAGE}.${filename}\"");
				error("Named prefix-less debhelper config files is not supported in compat 15 and later")
					if not compat(14);
				warning('Named prefix-less debhelper config files will trigger an error in compat 15 or later');
			}
			if ($nameless_variant_handling or (not defined($nameless_variant_handling) and $package eq $dh{MAINPACKAGE})) {
				push(@try, $nameless_variant);
				if (getpackages() > 1 and not $nameless_variant_handling and not compat(13) and -f $nameless_variant) {
					warning('The use of prefix-less debhelper config files is deprecated.');
					warning("Please rename \"${nameless_variant}\" to \"debian/$dh{MAINPACKAGE}.${filename}\"");
					error("Prefix-less debhelper config files is not supported in compat 15 and later")
						if not compat(14);
					warning('Prefix-less debhelper config files will trigger an error in compat 15 or later');
				}
			}
		}
		foreach my $file (@try) {
			return $file if -f $file;
		}

		return "";
	}

	# Used by dh to ditch some caches that makes assumptions about
	# dh_-tools can do, which does not hold for override targets.
	sub dh_clear_unsafe_cache {
		%_check_expensive = ();
	}
}

# Pass it a name of a binary package, it returns the name to prefix to files
# in debian/ for this package.
sub pkgext {
	my ($package) = @_;
	return "$package.";
}

# Pass it the name of a binary package, it returns the name to install
# files by in eg, etc. Normally this is the same, but --name can override
# it.
sub pkgfilename {
	my $package=shift;

	if (defined $dh{NAME}) {
		return $dh{NAME};
	}
	return $package;
}

# Returns 1 if the package is a native debian package, null otherwise.
# As a side effect, sets $dh{VERSION} to the version of this package.
sub isnative {
	my ($package) = @_;
	my $cache_key = $package;

	state (%isnative_cache, %pkg_version);

	if (exists($isnative_cache{$cache_key})) {
		$dh{VERSION} = $pkg_version{$cache_key};
		return $isnative_cache{$cache_key};
	}

	# Make sure we look at the correct changelog.
	local $dh{NAME};
	delete($dh{NAME});
	my $isnative_changelog = pkgfile(
		{
			'internal-nameless-variant-handling' => 0,
			'named'                              => 0,
			'support-architecture-restriction'   => 0,
		},
		$package,
		'changelog',
	);
	if (! $isnative_changelog) {
		$isnative_changelog = "debian/changelog";
		$cache_key = '_source';
		# check if we looked up the default changelog
		if (exists($isnative_cache{$cache_key})) {
			$dh{VERSION} = $pkg_version{$cache_key};
			return $isnative_cache{$cache_key};
		}
	}

	if (not %isnative_cache) {
		require Dpkg::Changelog::Parse;
	}

	my $res = Dpkg::Changelog::Parse::changelog_parse(
		file => $isnative_changelog,
		compression => 0,
	);
	if (not defined($res)) {
		error("No changelog entries for $package!? (changelog file: ${isnative_changelog})");
	}
	my $version = $res->{'Version'};
	# Do we have a valid version?
	if (not defined($version) or not $version->is_valid) {
		error("changelog parse failure; invalid or missing version");
	}
	# Get and cache the package version.
	$dh{VERSION} = $pkg_version{$cache_key} = $version->as_string;

	# Is this a native Debian package?
	if (index($dh{VERSION}, '-') > -1) {
		return $isnative_cache{$cache_key} = 0;
	} else {
		return $isnative_cache{$cache_key} = 1;
	}
}

sub _tool_version {
	return $DH_TOOL_VERSION if defined($DH_TOOL_VERSION);
	if (defined($main::VERSION)) {
		$DH_TOOL_VERSION = $main::VERSION;
	}
	if (defined($DH_TOOL_VERSION) and $DH_TOOL_VERSION eq DH_BUILTIN_VERSION) {
		my $version = "UNRELEASED-${\MAX_COMPAT_LEVEL}";
		eval {
			require Debian::Debhelper::Dh_Version;
			$version = $Debian::Debhelper::Dh_Version::version;
		};
		$DH_TOOL_VERSION = $version;
	} else {
		$DH_TOOL_VERSION //= 'UNDECLARED';
	}
	return $DH_TOOL_VERSION;
}

# Automatically add a shell script snippet to a debian script.
# Only works if the script has #DEBHELPER# in it.
#
# Parameters:
# 1: package
# 2: script to add to
# 3: filename of snippet
# 4: either text: shell-quoted sed to run on the snippet. Ie, 's/#PACKAGE#/$PACKAGE/'
#    or a sub to run on each line of the snippet. Ie sub { s/#PACKAGE#/$PACKAGE/ }
#    or a hashref with keys being variables and values being their replacement.  Ie. { PACKAGE => $PACKAGE }
# 5: Internal usage only
sub autoscript {
	my ($package, $script, $filename, $sed, $extra_options) = @_;

	my $tool_version = _tool_version();
	# This is the file we will modify.
	my $outfile="debian/".pkgext($package)."$script.debhelper";
	if ($extra_options && exists($extra_options->{'snippet-order'})) {
		my $order = $extra_options->{'snippet-order'};
		error("Internal error - snippet order set to unknown value: \"${order}\"")
			if $order ne 'service';
		$outfile = generated_file($package, "${script}.${order}");
	}

	# Figure out what shell script snippet to use.
	my $infile;
	if (defined($ENV{DH_AUTOSCRIPTDIR}) && 
	    -e "$ENV{DH_AUTOSCRIPTDIR}/$filename") {
		$infile="$ENV{DH_AUTOSCRIPTDIR}/$filename";
	}
	else {
		for my $dir (@DATA_INC_PATH) {
			my $path = "${dir}/autoscripts/${filename}";
			if (-e $path) {
				$infile = $path;
				last;
			}
		}
		if (not defined($infile)) {
			my @dirs = map { "$_/autoscripts" } @DATA_INC_PATH;
			unshift(@dirs, $ENV{DH_AUTOSCRIPTDIR}) if exists($ENV{DH_AUTOSCRIPTDIR});
			error("Could not find autoscript $filename (search path: " . join(':', @dirs) . ')');
		}
	}

	if (-e $outfile && ($script eq 'postrm' || $script eq 'prerm')) {
		# Add fragments to top so they run in reverse order when removing.
		if (not defined($sed) or ref($sed)) {
			verbose_print("[META] Prepend autosnippet \"$filename\" to $script [${outfile}.new]");
			if (not $dh{NO_ACT}) {
				open(my $out_fd, '>', "${outfile}.new") or error("open(${outfile}.new): $!");
				print {$out_fd} '# Automatically added by ' . $TOOL_NAME . "/${tool_version}\n";
				autoscript_sed($sed, $infile, undef, $out_fd);
				print {$out_fd} "# End automatically added section\n";
				open(my $in_fd, '<', $outfile) or error("open($outfile): $!");
				while (my $line = <$in_fd>) {
					print {$out_fd} $line;
				}
				close($in_fd);
				close($out_fd) or error("close(${outfile}.new): $!");
			}
		} else {
			complex_doit("echo \"# Automatically added by ".$TOOL_NAME."/${tool_version}\"> $outfile.new");
			autoscript_sed($sed, $infile, "$outfile.new");
			complex_doit("echo '# End automatically added section' >> $outfile.new");
			complex_doit("cat $outfile >> $outfile.new");
		}
		rename_path("${outfile}.new", $outfile);
	} elsif (not defined($sed) or ref($sed)) {
		verbose_print("[META] Append autosnippet \"$filename\" to $script [${outfile}]");
		if (not $dh{NO_ACT}) {
			open(my $out_fd, '>>', $outfile) or error("open(${outfile}): $!");
			print {$out_fd} '# Automatically added by ' . $TOOL_NAME . "/${tool_version}\n";
			autoscript_sed($sed, $infile, undef, $out_fd);
			print {$out_fd} "# End automatically added section\n";
			close($out_fd) or error("close(${outfile}): $!");
		}
	} else {
		complex_doit("echo \"# Automatically added by ".$TOOL_NAME."/${tool_version}\">> $outfile");
		autoscript_sed($sed, $infile, $outfile);
		complex_doit("echo '# End automatically added section' >> $outfile");
	}
}

sub autoscript_sed {
	my ($sed, $infile, $outfile, $out_fd) = @_;
	if (not defined($sed) or ref($sed)) {
		my $out = $out_fd;
		open(my $in, '<', $infile) or error("open $infile failed: $!");
		if (not defined($out_fd)) {
			open($out, '>>', $outfile) or error("open($outfile): $!");
		}
		if (not defined($sed) or ref($sed) eq 'CODE') {
			while (<$in>) { $sed->() if $sed; print {$out} $_; }
		} else {
			my $rstr = sprintf('#(%s)#', join('|', reverse(sort(keys(%$sed)))));
			my $regex = qr/$rstr/;
			while (my $line = <$in>) {
				$line =~ s/$regex/$sed->{$1}/eg;
				print {$out} $line;
			}
		}
		if (not defined($out_fd)) {
			close($out) or error("close $outfile failed: $!");
		}
		close($in) or error("close $infile failed: $!");
	}
	else {
		error("Internal error - passed open handle for legacy method") if defined($out_fd);
		complex_doit("sed \"$sed\" $infile >> $outfile");
	}
}

# Adds a trigger to the package
{
	my %VALID_TRIGGER_TYPES = map { $_ => 1 } qw(
		interest interest-await interest-noawait
		activate activate-await activate-noawait
	);

	sub autotrigger {
		my ($package, $trigger_type, $trigger_target) = @_;
		my ($triggers_file, $ifd, $tool_version);

		if (not exists($VALID_TRIGGER_TYPES{$trigger_type})) {
			require Carp;
			Carp::confess("Invalid/unknown trigger ${trigger_type}");
		}
		return if $dh{NO_ACT};

		$tool_version = _tool_version();
		$triggers_file = generated_file($package, 'triggers');
		if ( -f $triggers_file ) {
			open($ifd, '<', $triggers_file)
				or error("open $triggers_file failed $!");
		} else {
			open($ifd, '<', '/dev/null')
				or error("open /dev/null failed $!");
		}
		open(my $ofd, '>', "${triggers_file}.new")
			or error("open ${triggers_file}.new failed: $!");
		while (my $line = <$ifd>) {
			next if $line =~ m{\A  \Q${trigger_type}\E  \s+
                                   \Q${trigger_target}\E (?:\s|\Z)
                              }x;
			print {$ofd} $line;
		}
		print {$ofd} '# Triggers added by ' . $TOOL_NAME . "/${tool_version}\n";
		print {$ofd} "${trigger_type} ${trigger_target}\n";
		close($ofd) or error("closing ${triggers_file}.new failed: $!");
		close($ifd);
		rename_path("${triggers_file}.new", $triggers_file);
	}
}

# Generated files are cleaned by dh_clean AND dh_prep
# - Package can be set to "_source" to generate a file relevant
#   for the source package (the meson build does this atm.).
#   Files for "_source" are only cleaned by dh_clean.
sub generated_file {
	my ($package, $filename, $mkdirs) = @_;
	my $dir = "debian/.debhelper/generated/${package}";
	my $path = "${dir}/${filename}";
	$mkdirs //= 1;
	mkdirs($dir) if $mkdirs;
	return $path;
}

sub _update_substvar {
	my ($substvar_file, $update_logic, $insert_logic) = @_;
	my @lines;
	my $changed = 0;
	if ( -f $substvar_file) {
		open(my $in, '<', $substvar_file) // error("open($substvar_file): $!");
		while (my $line = <$in>) {
			chomp($line);
			my $orig_value = $line;
			my $updated_value = $update_logic->($line);
			$changed ||= !defined($updated_value) || $orig_value ne $updated_value;
			push(@lines, $updated_value) if defined($updated_value);
		}
		close($in);
	}
	my $len = scalar(@lines);
	push(@lines, $insert_logic->()) if $insert_logic;
	$changed ||= $len != scalar(@lines);
	if ($changed && !$dh{NO_ACT}) {
		open(my $out, '>', "${substvar_file}.new") // error("open(${substvar_file}.new, \"w\"): $!");
		for my $line (@lines) {
			print {$out} "$line\n";
		}
		close($out) // error("close(${substvar_file}.new): $!");
		rename_path("${substvar_file}.new", $substvar_file);
	}
	return;
}

# Removes a whole substvar line.
sub delsubstvar {
	my ($package, $substvar) = @_;
	my $ext = pkgext($package);
	my $substvarfile = "debian/${ext}substvars";

	return _update_substvar($substvarfile, sub {
		my ($line) = @_;
		return $line if $line !~ m/^\Q${substvar}\E[?]?=/;
		return;
	});
}
				
# Adds a dependency on some package to the specified
# substvar in a package's substvar's file.
sub addsubstvar {
	my ($package, $substvar, $deppackage, $verinfo, $remove) = @_;
	my ($present);
	my $ext = pkgext($package);
	my $substvarfile = "debian/${ext}substvars";
	my $str = $deppackage;
	$str .= " ($verinfo)" if defined $verinfo && length $verinfo;

	if (not defined($deppackage) and not $remove) {
		error("Bug in helper: Must provide a value for addsubstvar (or set the remove flag, but then use delsubstvar instead)")
	}

	if (defined($str) and $str =~ m/[\n]/) {
		$str =~ s/\n/\\n/g;
		# Per #1026014
		warning('Unescaped newlines in the value of a substvars can cause broken substvars files (see #1025714).');
		warning("Hint: If you really need a newline character, provide it as \"\${Newline}\".");
		error("Bug in helper: The substvar must not contain a raw newline character (${substvar}=${str})");
	}

	my $update_logic = sub {
		my ($line) = @_;
		return $line if $line !~ m/^\Q${substvar}\E([?]?=)(.*)/;
		my $assignment_type = $1;
		my %items = map { $_ => 1 } split(", ", $2);
		$present = 1;
		if ($remove) {
			# Unchanged; we can avoid rewriting the file.
			return $line if not exists($items{$str});
			delete($items{$str});
			my $replacement = join(", ", sort(keys(%items)));
			return "${substvar}${assignment_type}${replacement}" if $replacement ne '';
			return;
		}
		# Unchanged; we can avoid rewriting the file.
		return $line if %items and exists($items{$str});

		$items{$str} = 1;
		return "${substvar}${assignment_type}" . join(", ", sort(keys(%items)));
	};
	my $insert_logic = sub {
		return ("${substvar}=${str}") if not $present and not $remove;
		return;
	};
	return _update_substvar($substvarfile, $update_logic, $insert_logic);
}

sub ensure_substvars_are_present {
	my ($file, @substvars) = @_;
	my (%vars, $fd);
	return 1 if $dh{NO_ACT};
	if (open($fd, '+<', $file)) {
		while (my $line = <$fd>) {
			my $k;
			($k, undef) = split(m/=/, $line, 2);
			$vars{$k} = 1 if $k;
		}
		# Fall-through and append the missing vars if any.
	} else {
		error("open(${file}) failed: $!") if $! != ENOENT;
		open($fd, '>', $file) or error("open(${file}) failed: $!");
	}

	for my $var (@substvars) {
		if (not exists($vars{$var})) {
			verbose_print("echo ${var}= >> ${file}");
			print ${fd} "${var}=\n";
			$vars{$var} = 1;
		}
	}
	close($fd) or error("close(${file}) failed: $!");
	return 1;
}

sub _glob_expand_error_default_msg {
	my ($pattern, $dir_ref) = @_;
	my $dir_list = join(', ', map { escape_shell($_) } @{$dir_ref});
	return "Cannot find (any matches for) \"${pattern}\" (tried in $dir_list)";
}

sub glob_expand_error_handler_reject {
	my $msg = _glob_expand_error_default_msg(@_);
	error("$msg\n");
	return;
}

sub glob_expand_error_handler_warn_and_discard {
	my $msg = _glob_expand_error_default_msg(@_);
	warning("$msg\n");
	return;
}

# Emulates the "old" glob mechanism; not recommended for new code as
# it permits some globs expand to nothing with only a warning.
sub glob_expand_error_handler_reject_nomagic_warn_discard {
	my ($pattern, $dir_ref) = @_;
	for my $dir (@{$dir_ref}) {
		my $full_pattern = "$dir/$pattern";
		my @matches = bsd_glob($full_pattern, GLOB_CSH & ~(GLOB_TILDE));
		if (@matches) {
			goto \&glob_expand_error_handler_reject;
		}
	}
	goto \&glob_expand_error_handler_warn_and_discard;
}

sub glob_expand_error_handler_silently_ignore {
	return;
}

sub glob_expand {
	my ($dir_ref, $error_handler, @patterns) = @_;
	my @dirs = @{$dir_ref};
	my @result;
	for my $pattern (@patterns) {
		my @m;
		for my $dir (@dirs) {
			my $full_pattern = "$dir/$pattern";
			@m = bsd_glob($full_pattern, GLOB_CSH & ~(GLOB_NOMAGIC|GLOB_TILDE));
			last if @m;
			# Handle "foo{bar}" pattern (#888251)
			if (-l $full_pattern or -e _) {
				push(@m, $full_pattern);
				last;
			}
		}
		if (not @m) {
			$error_handler //= \&glob_expand_error_handler_reject;
			$error_handler->($pattern, $dir_ref);
		}
		push(@result, @m);
	}
	return @result;
}


my %BUILT_IN_SUBST = (
	'Space'        => ' ',
	'Dollar'       => '$',
	'Newline'      => "\n",
	'Tab'          => "\t",
);

sub _variable_substitution {
	my ($text, $loc) = @_;
	return $text if index($text, '$') < 0;
	my $pos = -1;
	my $subst_count = 0;
	my $expansion_count = 0;
	my $current_size = length($text);
	my $expansion_size_limit = _VAR_SUBST_EXPANSION_DYNAMIC_EXPANSION_FACTOR_LIMIT * $current_size;
	$expansion_size_limit = _VAR_SUBST_EXPANSION_MIN_SUPPORTED_SIZE_LIMIT
		if $expansion_size_limit < _VAR_SUBST_EXPANSION_MIN_SUPPORTED_SIZE_LIMIT;
	1 while ($text =~ s<
			\$\{([A-Za-z0-9][-_:0-9A-Za-z]*)\}  # Match ${something} and replace it
		>[
			my $match = $1;
			my $new_pos = pos()//-1;
			my $value;

			if ($pos == $new_pos) {
				# Safe-guard in case we ever implement recursive expansion
				error("Error substituting in ${loc} (at position $pos); recursion limit while expanding \${${match}}")
					if (++$subst_count >= _VAR_SUBST_SAME_POSITION_RECURSION_LIMIT);
			} else {
				$subst_count = 0;
				$pos = $new_pos;
				if (++$expansion_count >= _VAR_SUBST_EXPANSION_COUNT_LIMIT) {
					error("Error substituting in ${loc}; substitution limit of ${expansion_count} reached");
				}
			}
			if (exists($BUILT_IN_SUBST{$match})) {
				$value = $BUILT_IN_SUBST{$match};
			} elsif ($match =~ m/^DEB_(?:BUILD|HOST|TARGET)_/) {
				$value = dpkg_architecture_value($match) //
					error(qq{Cannot expand "\${${match}}" in ${loc} as it is not a known dpkg-architecture value});
			} elsif ($match =~ m/^env:(.+)/) {
				my $env_var = $1;
				$value = $ENV{$env_var} //
					error(qq{Cannot expand "\${${match}}" in ${loc} as the ENV variable "${env_var}" is unset});
			}
			error(qq{Cannot resolve variable "\${$match}" in ${loc}})
				if not defined($value);
			# We do not support recursive expansion.
			$value =~ s/\$/\$\{\}/;
			$current_size += length($value) - length($match) - 3;
			if ($current_size > $expansion_size_limit) {
				error("Refusing to expand \${${match}} in ${loc} - the original input seems to grow beyond reasonable'
						 . ' limits!");
			}
			$value;
		]gex);
	$text =~ s/\$\{\}/\$/g;

	return $text;
}

# Reads in the specified file, one line at a time. splits on words, 
# and returns an array of arrays of the contents.
# If a value is passed in as the second parameter, then glob
# expansion is done in the directory specified by the parameter ("." is
# frequently a good choice).
# In compat 13+, it will do variable expansion (after splitting the lines
# into words)
sub filedoublearray {
	my ($file, $globdir, $error_handler) = @_;

	# executable config files are a v9 thing.
	my $x=! compat(8) && -x $file;
	my $expand_patterns = compat(12) ? 0 : 1;
	my $source;
	if ($x) {
		require Cwd;
		my $cmd=Cwd::abs_path($file);
		$ENV{"DH_CONFIG_ACT_ON_PACKAGES"} = join(",", @{$dh{"DOPACKAGES"}});
		open(DH_FARRAY_IN, '-|', $cmd) || error("cannot run $file: $!");
		delete $ENV{"DH_CONFIG_ACT_ON_PACKAGES"};
		$source = "output of ./${file}";
	}
	else {
		open (DH_FARRAY_IN, '<', $file) || error("cannot read $file: $!");
		$source = $file;
	}

	my @ret;
	while (<DH_FARRAY_IN>) {
		chomp;
		if ($x) {
			if (m/^\s++$/) {
				error("Executable config file $file produced a non-empty whitespace-only line");
			}
		} else {
			s/^\s++//;
			next if /^#/;
			s/\s++$//;
		}
		# We always ignore/permit empty lines
		next if $_ eq '';
		my @line;
		my $source_ref = "${source} (line $.)";

		if (defined($globdir) && ! $x) {
			if (ref($globdir)) {
				my @patterns = split;
				if ($expand_patterns) {
					@patterns = map {_variable_substitution($_, $source_ref)} @patterns;
				}
				push(@line, glob_expand($globdir, $error_handler, @patterns));
			} else {
				# Legacy call - Silently discards globs that match nothing.
				#
				# The tricky bit is that the glob expansion is done
				# as if we were in the specified directory, so the
				# filenames that come out are relative to it.
				foreach (map { glob "$globdir/$_" } split) {
					s#^$globdir/##;
					if ($expand_patterns) {
						$_ = _variable_substitution($_, $source_ref);
					}
					push @line, $_;
				}
			}
		}
		else {
			@line = split;
			if ($expand_patterns) {
				@line = map {_variable_substitution($_, $source_ref)} @line;
			}
		}
		push @ret, [@line];
	}

	if (!close(DH_FARRAY_IN)) {
		if ($x) {
			_executable_dh_config_file_failed($file, $!, $?);
		} else {
			error("problem reading $file: $!");
		}
	}
	
	return @ret;
}

# Reads in the specified file, one word at a time, and returns an array of
# the result. Can do globbing as does filedoublearray.
sub filearray {
	return map { @$_ } filedoublearray(@_);
}

# Passed a filename, returns true if -X says that file should be excluded.
sub excludefile {
        my $filename = shift;
        foreach my $f (@{$dh{EXCLUDE}}) {
                return 1 if $filename =~ /\Q$f\E/;
        }
        return 0;
}

sub dpkg_architecture_value {
	my $var = shift;
	state %dpkg_arch_output;
	if (exists($ENV{$var})) {
		my $value = $ENV{$var};
		return $value if $value ne q{};
		warning("ENV[$var] is set to the empty string.  It has been ignored to avoid bugs like #862842");
		delete($ENV{$var});
	}
	if (! exists($dpkg_arch_output{$var})) {
		# Return here if we already consulted dpkg-architecture
		# (saves a fork+exec on unknown variables)
		return if %dpkg_arch_output;

		open(my $fd, '-|', 'dpkg-architecture')
			or error("dpkg-architecture failed");
		while (my $line = <$fd>) {
			chomp($line);
			my ($k, $v) = split(/=/, $line, 2);
			$dpkg_arch_output{$k} = $v;
		}
		close($fd);
	}
	return $dpkg_arch_output{$var};
}

# Confusing name for hostarch
sub buildarch {
	deprecated_functionality('buildarch() is deprecated and replaced by hostarch()', 12);
	goto \&hostarch;
}

# Returns the architecture that will run binaries produced (DEB_HOST_ARCH)
sub hostarch {
	dpkg_architecture_value('DEB_HOST_ARCH');
}

# Returns a truth value if this seems to be a cross-compile
sub is_cross_compiling {
	return dpkg_architecture_value("DEB_BUILD_GNU_TYPE")
	    ne dpkg_architecture_value("DEB_HOST_GNU_TYPE");
}

# Passed an arch and a space-separated list of arches to match against, returns true if matched
sub samearch {
	my $arch=shift;
	my @archlist=split(/\s+/,shift);
	state %knownsame;

	foreach my $a (@archlist) {
		if (exists $knownsame{$arch}{$a}) {
			return 1 if $knownsame{$arch}{$a};
			next;
		}

		require Dpkg::Arch;
		if (Dpkg::Arch::debarch_is($arch, $a)) {
			return $knownsame{$arch}{$a}=1;
		}
		else {
			$knownsame{$arch}{$a}=0;
		}
	}

	return 0;
}


# Returns a list of packages in the control file.
# Pass "arch" or "indep" to specify arch-dependent (that will be built
# for the system's arch) or independent. If nothing is specified,
# returns all packages. Also, "both" returns the union of "arch" and "indep"
# packages.
#
# As a side effect, populates %package_arches and %package_types
# with the types of all packages (not only those returned).
my (%packages_by_type, $sourcepackage, %dh_bd_sequences, %package_fields);

# Resets the arrays; used mostly for testing
sub resetpackages {
	undef $sourcepackage;
	%package_fields = %packages_by_type = ();
	%dh_bd_sequences = ();
}

# Returns source package name
sub sourcepackage {
	getpackages() if not defined($sourcepackage);
	return $sourcepackage;
}

sub getpackages {
	my ($type) = @_;
	error("getpackages: First argument must be one of \"arch\", \"indep\", or \"both\"")
		if defined($type) and $type ne 'both' and $type ne 'indep' and $type ne 'arch';

	$type //= 'all-listed-in-control-file';

	if (not %packages_by_type) {
		_parse_debian_control();
	}
	return @{$packages_by_type{$type}};
}

sub _strip_spaces {
	my ($v) = @_;
	return if not defined($v);
	$v =~ s/^\s++//;
	$v =~ s/\s++$//;
	return $v;
}

sub _parse_debian_control {
	my $valid_pkg_re = qr{^${PKGNAME_REGEX}$}o;
	my (%seen, @profiles, $source_section, $cross_target_arch, %field_values,
		$field_name, %bd_fields, $bd_field_value, %seen_fields, $fd);
	if (exists $ENV{'DEB_BUILD_PROFILES'}) {
		@profiles=split /\s+/, $ENV{'DEB_BUILD_PROFILES'};
	}
	if (not open($fd, '<', 'debian/control')) {
		error("\"debian/control\" not found. Are you sure you are in the correct directory?")
			if $! == ENOENT;
		error("cannot read debian/control: $!\n");
	};

	$packages_by_type{$_} = [] for qw(both indep arch all-listed-in-control-file);
	while (<$fd>) {
		chomp;
		s/\s+$//;
		next if m/^\s*+\#/;

		if (/^\s/) {
			if (not %seen_fields) {
				error("Continuation line seen before first stanza in debian/control (line $.)");
			}
			# Continuation line
			s/^\s[.]?//;
			push(@{$bd_field_value}, $_) if $bd_field_value;
			error('X-DH-Compat should not need to span multiple lines')
				if ($field_name and $field_name eq 'x-dh-compat');

			# Ensure it is not completely empty or the code below will assume the paragraph ended
			$_ = '.' if not $_;
		} elsif (not $_ and not %seen_fields) {
			# Ignore empty lines before first stanza
			next;
		} elsif ($_) {
			my ($value);

			if (m/^($DEB822_FIELD_REGEX):\s*(.*)/o) {
				($field_name, $value) = (lc($1), $2);
				if (exists($seen_fields{$field_name})) {
					my $first_time = $seen_fields{$field_name};
					error("${field_name}-field appears twice in the same stanza of debian/control. " .
						  "First time on line $first_time, second time: $.");
				}
				$seen_fields{$field_name} = $.;
				$bd_field_value = undef;
			} else {
				# Invalid file
				error("Parse error in debian/control, line $., read: $_");
			}
			if ($field_name eq 'source') {
				$sourcepackage = $value;
				if ($sourcepackage !~ $valid_pkg_re) {
					error('Source-field must be a valid package name, ' .
						  "got: \"${sourcepackage}\", should match \"${valid_pkg_re}\"");
				}
				next;
			} elsif ($field_name eq 'section') {
				$source_section = $value;
				next;
			} elsif ($field_name =~ /^(?:build-depends(?:-arch|-indep)?)$/) {
				$bd_field_value = [$value];
				$bd_fields{$field_name} = $bd_field_value;
			} elsif ($field_name eq 'x-dh-compat') {
				error('The X-DH-Compat field must contain a single integer') if ($value !~ m/^\d+$/);
				$compat_from_dctrl = int($value);
			}
		}
		last if not $_ or eof;
	}
	error("could not find Source: line in control file.") if not defined($sourcepackage);
	$compat_from_dctrl //= -1;
	if (%bd_fields) {
		my ($dh_compat_bd, $final_level);
		my %field2addon_type = (
			'build-depends' => 'both',
			'build-depends-arch' => 'arch',
			'build-depends-indep' => 'indep',
		);
		for my $field (sort(keys(%bd_fields))) {
			my $value = join(' ', @{$bd_fields{$field}});
			$value =~ s/^\s*//;
			$value =~ s/\s*(?:,\s*)?$//;
			for my $dep (split(/\s*,\s*/, $value)) {
				if ($dep =~ m/^debhelper-compat\s*[(]\s*=\s*(${PKGVERSION_REGEX})\s*[)]$/) {
					my $version = $1;
					if ($version =~m/^(\d+)\D.*$/) {
						my $guessed_compat = $1;
						warning("Please use the compat level as the exact version rather than the full version.");
						warning("  Perhaps you meant: debhelper-compat (= ${guessed_compat})");
						if ($field ne 'build-depends') {
							warning(" * Also, please move the declaration to Build-Depends (it was found in ${field})");
						}
						error("Invalid compat level ${version}, derived from relation: ${dep}");
					}
					$final_level = $version;
					error("Duplicate debhelper-compat build-dependency: ${dh_compat_bd} vs. ${dep}") if $dh_compat_bd;
					error("The debhelper-compat build-dependency must be in the Build-Depends field (not $field)")
						if $field ne 'build-depends';
					$dh_compat_bd = $dep;
				} elsif ($dep =~ m/^debhelper-compat\s*(?:\S.*)?$/) {
					my $clevel = "${\MAX_COMPAT_LEVEL}";
					eval {
						require Debian::Debhelper::Dh_Version;
						$clevel = $Debian::Debhelper::Dh_Version::version;
					};
					$clevel =~ s/^\d+\K\D.*$//;
					warning("Found invalid debhelper-compat relation: ${dep}");
					warning(" * Please format the relation as (example): debhelper-compat (= ${clevel})");
					warning(" * Note that alternatives, architecture restrictions, build-profiles etc. are not supported.");
					if ($field ne 'build-depends') {
						warning(" * Also, please move the declaration to Build-Depends (it was found in ${field})");
					}
					warning(" * If this is not possible, then please remove the debhelper-compat relation and insert the");
					warning("   compat level into the file debian/compat.  (E.g. \"echo ${clevel} > debian/compat\")");
					error("Could not parse desired debhelper compat level from relation: $dep");
				}
				# Build-Depends on dh-sequence-<foo> OR dh-sequence-<foo> (<op> <version>)
				if ($PARSE_DH_SEQUENCE_INFO and $dep =~ m/^dh-sequence-(${PKGNAME_REGEX})\s*(?:[(]\s*(?:[<>]?=|<<|>>)\s*(?:${PKGVERSION_REGEX})\s*[)])?(\s*[^\|]+[]>]\s*)?$/) {
					my $sequence = $1;
					my $has_profile_or_arch_restriction = $2 ? 1 : 0;
					my $addon_type = $field2addon_type{$field};
					if (not defined($field)) {
						warning("Cannot map ${field} to an add-on type (like \"both\", \"indep\" or \"arch\")");
						error("Internal error: Cannot satisfy dh sequence add-on request for sequence ${sequence} via ${field}.");
					}
					if (defined($dh_bd_sequences{$sequence})) {
						error("Saw $dep multiple times (last time in $field).  However dh only support that build-"
							. 'dependency at most once across all Build-Depends(-Arch|-Indep) fields');
					}
					if ($has_profile_or_arch_restriction) {
						require Dpkg::Deps;
						my $dpkg_dep = Dpkg::Deps::deps_parse($dep, build_profiles => \@profiles, build_dep => 1,
							reduce_restrictions => 1);
						# If dpkg reduces it to nothing, then it was not relevant for us after all
						next if not $dpkg_dep;
					}
					$dh_bd_sequences{$sequence} = $addon_type;
				}
			}
		}
		$compat_from_bd = $final_level // -1;
	} else {
		$compat_from_bd = -1;
	}

	error(
		'The X-DH-Compat field cannot be used together with a Build-Dependency on debhelper-compat.'
			. ' Please remove one of the two.'
	) if ($compat_from_bd > -1 and $compat_from_dctrl > -1);


	%seen_fields = ();
	$field_name = undef;

	while (<$fd>) {
		chomp;
		s/\s+$//;
		if (m/^\#/) {
			# Skip unless EOF for the special case where the last line
			# is a comment line directly after the last stanza.  In
			# that case we need to "commit" the last stanza as well or
			# we end up omitting the last package.
			next if not eof;
			$_  = '';
		}

		if (/^\s/) {
			# Continuation line
			if (not %seen_fields) {
				error("Continuation line seen outside stanza in debian/control (line $.)");
			}
			s/^\s[.]?//;
			$field_values{$field_name} .= ' ' . $_;
			# Ensure it is not completely empty or the code below will assume the paragraph ended
			$_ = '.' if not $_;
		} elsif (not $_ and not %seen_fields) {
			# Ignore empty lines before first stanza
			next;
		} elsif ($_) {
			my ($value);
			if (m/^($DEB822_FIELD_REGEX):\s*(.*)/o) {
				($field_name, $value) = (lc($1), $2);
				if (exists($seen_fields{$field_name})) {
					my $first_time = $seen_fields{$field_name};
					error("${field_name}-field appears twice in the same stanza of debian/control. " .
						  "First time on line $first_time, second time: $.");
				}

				if ($field_name =~ m/^(?:x[bc]*-)?package-type$/) {
					# Normalize variants into the main "Package-Type" field
					$field_name = 'package-type';
					if (exists($seen_fields{$field_name})) {
						my $package = _strip_spaces($field_values{'package'} // '');
						my $help = "(issue seen prior \"Package\"-field)";
						$help = "for package ${package}" if $package;
						error("Multiple definitions of (X-)Package-Type in line $. ${help}");
					}
				}
				$seen_fields{$field_name} = $.;
				$field_values{$field_name} = $value;
				$bd_field_value = undef;
			} else {
				# Invalid file
				error("Parse error in debian/control, line $., read: $_");
			}
		}
		if (!$_ or eof) { # end of stanza.
			if (%field_values) {
				my $package = _strip_spaces($field_values{'package'} // '');
				my $build_profiles = $field_values{'build-profiles'};
				my $included_in_build_profile = 1;
				my $arch = _strip_spaces($field_values{'architecture'} // '');
				my $cross_type = _strip_spaces($field_values{'x-dh-build-for-type'} // 'host');

				# Detect duplicate package names in the same control file.
				if ($package eq '') {
					error("Binary paragraph ending on line $. is missing mandatory \"Package\"-field");
				}
				if (! $seen{$package}) {
					$seen{$package}=1;
				} else {
					error("debian/control has a duplicate entry for $package");
				}
				if ($package !~ $valid_pkg_re) {
					error('Package-field must be a valid package name, ' .
						  "got: \"${package}\", should match \"${valid_pkg_re}\"");
				}
				if ($cross_type ne 'host' and $cross_type ne 'target') {
					error("Unknown value of X-DH-Build-For-Type \"$cross_type\" for package $package");
				}

				$field_values{'package-type'} = _strip_spaces($field_values{'package-type'} // 'deb');
				$field_values{'architecture'} = $arch;
				$field_values{'multi-arch'} = _strip_spaces($field_values{'multi-arch'} // '');
				$field_values{'section'} = _strip_spaces($field_values{'section'} // $source_section);
				$field_values{'x-dh-build-for-type'} = $cross_type;
				$field_values{'x-time64-compat'} = _strip_spaces($field_values{'x-time64-compat'} // '');
				my %fields = %field_values;
				$package_fields{$package} = \%fields;
				push(@{$packages_by_type{'all-listed-in-control-file'}}, $package);

				if (defined($build_profiles)) {
					eval {
						# rely on libdpkg-perl providing the parsing functions
						# because if we work on a package with a Build-Profiles
						# field, then a high enough version of dpkg-dev is needed
						# anyways
						require Dpkg::BuildProfiles;
						my @restrictions = Dpkg::BuildProfiles::parse_build_profiles($build_profiles);
						if (@restrictions) {
							$included_in_build_profile = Dpkg::BuildProfiles::evaluate_restriction_formula(
								\@restrictions,
								\@profiles);
						}
					};
					if ($@) {
						error("The control file has a Build-Profiles field. Requires libdpkg-perl >= 1.17.14");
					}
				}

				if ($included_in_build_profile) {
					if ($arch eq 'all') {
						push(@{$packages_by_type{'indep'}}, $package);
						push(@{$packages_by_type{'both'}}, $package);
					} else {
						my $included = 0;
						$included = 1 if $arch eq 'any';
						if (not $included) {
							my $desired_arch = hostarch();
							if ($cross_type eq 'target') {
								$cross_target_arch //= dpkg_architecture_value('DEB_TARGET_ARCH');
								$desired_arch = $cross_target_arch;
							}
							$included = 1 if samearch($desired_arch, $arch);
						}
						if ($included) {
								push(@{$packages_by_type{'arch'}}, $package);
								push(@{$packages_by_type{'both'}}, $package);
						}
					}
				}
			}
			%field_values = ();
			%seen_fields = ();
		}
	}
	close($fd);
}

# Return true if we should use root.
# - Takes an optional keyword; if passed, this will return true if the keyword is listed in R^3 (Rules-Requires-Root)
# - If the optional keyword is omitted or not present in R^3 and R^3 is not 'binary-targets', then returns false
# - Returns true otherwise (i.e. keyword is in R^3 or R^3 is 'binary-targets')
sub should_use_root {
	my ($keyword) = @_;
	my $rrr_env = $ENV{'DEB_RULES_REQUIRES_ROOT'} // 'binary-targets';
	$rrr_env =~ s/^\s++//;
	$rrr_env =~ s/\s++$//;
	return 0 if $rrr_env eq 'no';
	return 1 if $rrr_env eq 'binary-targets';
	return 0 if not defined($keyword);

	state %rrr = map { $_ => 1 } split(' ', $rrr_env);
	return 1 if exists($rrr{$keyword});
	return 0;
}

# Returns the "gain root command" as a list suitable for passing as a part of the command to "doit()"
sub gain_root_cmd {
	my $raw_cmd = $ENV{DEB_GAIN_ROOT_CMD};
	return if not defined($raw_cmd) or $raw_cmd =~ m/^\s*+$/;
	return split(' ', $raw_cmd);
}

sub root_requirements {
	my $rrr_env = $ENV{'DEB_RULES_REQUIRES_ROOT'} // 'binary-targets';
	$rrr_env =~ s/^\s++//;
	$rrr_env =~ s/\s++$//;
	return 'none' if $rrr_env eq 'no';
	return 'legacy-root' if $rrr_env eq 'binary-targets';
	return 'targeted-promotion';
}

# Returns the arch a package will build for.
#
# Deprecated: please switch to the more descriptive
# package_binary_arch function instead.
sub package_arch {
	my $package=shift;
	return package_binary_arch($package);
}

# Returns the architecture going into the resulting .deb, i.e. the
# host architecture or "all".
sub package_binary_arch {
	my $package=shift;

	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		return hostarch();
	}
	return 'all' if $package_fields{$package}{'architecture'} eq 'all';
	return dpkg_architecture_value('DEB_TARGET_ARCH') if package_cross_type($package) eq 'target';
	return hostarch();
}

# Returns the Architecture: value which the package declared.
sub package_declared_arch {
	my $package=shift;

	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		return hostarch();
	}
	return $package_fields{$package}{'architecture'};
}

# Returns whether the package specified Architecture: all
sub package_is_arch_all {
	my $package=shift;

	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		return hostarch();
	}
	return $package_fields{$package}{'architecture'} eq 'all';
}

# Returns the multiarch value of a package.
sub package_multiarch {
	my $package=shift;

	# Test the architecture field instead, as it is common for a
	# package to not have a multi-arch value.
	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		# The only sane default
		return 'no';
	}
	return $package_fields{$package}{'multi-arch'} // 'no';
}

sub package_is_essential {
	my ($package) = @_;

	# Test the architecture field instead, as it is common for a
	# package to not have a multi-arch value.
	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		# The only sane default
		return 0;
	}
	my $essential = $package_fields{$package}{'essential'} // 'no';
	return $essential eq 'yes';
}

sub package_field {
	my ($package, $field, $default_value) = @_;
		if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		return $default_value;
	}
	return $package_fields{$package}{$field} if exists($package_fields{$package}{$field});
	return $default_value;
}


# Returns the (raw) section value of a package (possibly including component).
sub package_section {
	my ($package) = @_;

	# Test the architecture field instead, as it is common for a
	# package to not have a multi-arch value.
	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		return 'unknown';
	}
	return $package_fields{$package}{'section'} // 'unknown';
}

sub package_cross_type {
	my ($package) = @_;

	# Test the architecture field instead, as it is common for a
	# package to not have a multi-arch value.
	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		return 'host';
	}
	return $package_fields{$package}{'x-dh-build-for-type'} // 'host';
}

sub package_type {
	my ($package) = @_;

	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		return DEFAULT_PACKAGE_TYPE;
	}
	return $package_fields{$package}{'package-type'};
}

sub t64_compat_name {
	my ($package) = @_;

	if (! exists($package_fields{$package})) {
		warning "package $package is not in control info";
		return '';
	}
	return $package_fields{$package}{'x-time64-compat'};
}

# Return true if a given package is really a udeb.
sub is_udeb {
	my $package=shift;
	
	return package_type($package) eq 'udeb';
}


sub process_pkg {
	my ($package) = @_;
	state %packages_to_process = map { $_ => 1 } @{$dh{DOPACKAGES}};
	return $packages_to_process{$package} // 0;
}

# Only useful for dh(1)
sub bd_dh_sequences {
	# Use $sourcepackage as check because %dh_bd_sequence can be empty
	# after running getpackages().
	getpackages() if not defined($sourcepackage);
	return \%dh_bd_sequences;
}

sub _concat_slurp_script_files {
	my (@files) = @_;
	my $res = '';
	for my $file (@files) {
		open(my $fd, '<', $file) or error("open($file) failed: $!");
		my $f = join('', <$fd>);
		close($fd);
		$res .= $f;
	}
	return $res;
}

sub _substitution_generator {
	my ($input) = @_;
	my $cache = {};
	return sub {
		my ($orig_key) = @_;
		return $cache->{$orig_key} if exists($cache->{$orig_key});
		my $value = exists($input->{$orig_key}) ? $input->{$orig_key} : undef;
		if (not defined($value)) {
			if ($orig_key =~ m/^DEB_(?:BUILD|HOST|TARGET)_/) {
				$value = dpkg_architecture_value($orig_key);
			} elsif ($orig_key =~ m{^ENV[.](\S+)$}) {
				$value = $ENV{$1} // '';
			}
		} elsif (ref($value) eq 'CODE') {
			$value = $value->($orig_key);
		} elsif ($value =~ s/^@//) {
			$value = _concat_slurp_script_files($value);
		}
		$cache->{$orig_key} = $value;
		return $value;
	};
}

sub debhelper_script_per_package_subst {
	my ($package, $provided_subst) = @_;
	my %vars = %{$provided_subst};
	$vars{'PACKAGE'} = $package if not exists($vars{'PACKAGE'});
	for my $var (keys(%{$provided_subst})) {
		if ($var !~ $Debian::Debhelper::Dh_Lib::MAINTSCRIPT_TOKEN_REGEX) {
			warning("User defined token ${var} does not match ${Debian::Debhelper::Dh_Lib::MAINTSCRIPT_TOKEN_REGEX}");
			error("Invalid provided token ${var}: It cannot be substituted as it does not follow the token name rules");
		}
		if ($var =~ m/^pkg[.]\Q${package}\E[.](.+)$/) {
			my $new_key = $1;
			$vars{$new_key} = $provided_subst->{$var};
		}
	}
	return \%vars;
}


# Handles #DEBHELPER# substitution in a script; also can generate a new
# script from scratch if none exists but there is a .debhelper file for it.
sub debhelper_script_subst {
	my ($package, $script, $extra_vars) = @_;

	my $tmp=tmpdir($package);
	my $ext=pkgext($package);
	my $file = pkgfile(
		{
			'named'                              => 0,
			'support-architecture-restriction'   => 0,
		},
		$package,
		$script,
	);
	my %variables = defined($extra_vars) ? %{$extra_vars} : ();
	my $service_script = generated_file($package, "${script}.service", 0);
	my @generated_scripts = ("debian/$ext$script.debhelper", $service_script);
	my $subst;
	@generated_scripts = grep { -f } @generated_scripts;
	if ($script eq 'prerm' or $script eq 'postrm') {
		@generated_scripts = reverse(@generated_scripts);
	}
	if (not exists($variables{'DEBHELPER'})) {
		$variables{'DEBHELPER'} = sub {
			return _concat_slurp_script_files(@generated_scripts);
		};
	}
	$subst = _substitution_generator(\%variables);

	if ($file ne '') {
		if ($dh{VERBOSE}) {
			verbose_print('cp -f ' . escape_shell($file) . " $tmp/DEBIAN/$script");
			verbose_print("[META] Replace #TOKEN#s in \"$tmp/DEBIAN/$script\"");
		}
		if (not $dh{NO_ACT}) {
			my $regex = qr{#(${MAINTSCRIPT_TOKEN_REGEX})#}o;
			open(my $out_fd, '>', "$tmp/DEBIAN/$script") or error("open($tmp/DEBIAN/$script) failed: $!");
			open(my $in_fd, '<', $file) or error("open($file) failed: $!");
			while (my $line = <$in_fd>) {
				$line =~ s{$regex}{$subst->($1) // "#${1}#"}ge;
				print {$out_fd} $line;
			}
			close($in_fd);
			close($out_fd) or error("close($tmp/DEBIAN/$script) failed: $!");
		}
		reset_perm_and_owner(0755, "$tmp/DEBIAN/$script");
	}
	elsif (@generated_scripts) {
		if ($dh{VERBOSE}) {
			verbose_print(q{printf '#!/bin/sh\nset -e\n' > } . "$tmp/DEBIAN/$script");
			verbose_print("cat @generated_scripts >> $tmp/DEBIAN/$script");
		}
		if (not $dh{NO_ACT}) {
			open(my $out_fd, '>', "$tmp/DEBIAN/$script") or error("open($tmp/DEBIAN/$script): $!");
			print {$out_fd} "#!/bin/sh\n";
			print {$out_fd} "set -e\n";
			for my $generated_script (@generated_scripts) {
				open(my $in_fd, '<', $generated_script)
					or error("open($generated_script) failed: $!");
				while (my $line = <$in_fd>) {
					print {$out_fd} $line;
				}
				close($in_fd);
			}
			close($out_fd) or error("close($tmp/DEBIAN/$script) failed: $!");
		}
		reset_perm_and_owner(0755, "$tmp/DEBIAN/$script");
	}
}

sub rm_files {
	my @files = @_;
	verbose_print('rm -f ' . escape_shell(@files))
		if $dh{VERBOSE};
	return 1 if $dh{NO_ACT};
	for my $file (@files) {
		if (not unlink($file) and $! != ENOENT) {
			error("unlink $file failed: $!");
		}
	}
	return 1;
}

sub make_symlink_raw_target {
	my ($src, $dest) = @_;
	verbose_print('ln -s ' . escape_shell($src, $dest))
		if $dh{VERBOSE};
	return 1 if $dh{NO_ACT};
	if (not symlink($src, $dest)) {
		error("symlink($src, $dest) failed: $!");
	}
	return 1;
}

# make_symlink($dest, $src[, $tmp]) creates a symlink from  $dest -> $src.
# if $tmp is given, $dest will be created within it.
# Usually $tmp should be the value of tmpdir($package);
sub make_symlink{
	my $dest = shift;
	my $src = _expand_path(shift);
	my $tmp = shift;
	$tmp = '' if not defined($tmp);

	if ($dest =~ m{(?:^|/)*[.]{2}(?:/|$)}) {
		error("Invalid destination/link name (contains \"..\"-segments): $dest");
	}

	$src =~ s{^(?:[.]/+)++}{};
	$dest =~ s{^(?:[.]/+)++}{};

	$src=~s:^/++::;
	$dest=~s:^/++::;

	if ($src eq $dest) {
		warning("skipping link from $src to self");
		return;
	}



	# Policy says that if the link is all within one toplevel
	# directory, it should be relative. If it's between
	# top level directories, leave it absolute.
	my @src_dirs = grep { $_ ne '.' } split(m:/+:,$src);
	my @dest_dirs = grep { $_ ne '.' } split(m:/+:,$dest);
	if (@src_dirs > 0 && $src_dirs[0] eq $dest_dirs[0]) {
		# Figure out how much of a path $src and $dest
		# share in common.
		my $x;
		for ($x=0; $x < @src_dirs && $src_dirs[$x] eq $dest_dirs[$x]; $x++) {}
		# Build up the new src.
		$src="";
		for (1..$#dest_dirs - $x) {
			$src.="../";
		}
		for ($x .. $#src_dirs) {
			$src.=$src_dirs[$_]."/";
		}
		if ($x > $#src_dirs && ! length $src) {
			$src="."; # special case
		}
		$src=~s:/$::;
	}
	else {
		# Make sure it's properly absolute.
		$src="/$src";
	}

	my $full_dest = "$tmp/$dest";
	if ( -l $full_dest ) {
		# All ok - we can always replace a link, and target directory must exists
	} elsif (-d _) {
		# We cannot replace a directory though
		error("link destination $full_dest is a directory");
	} else {
		# Make sure the directory the link will be in exists.
		my $basedir=dirname($full_dest);
		install_dir($basedir);
	}
	rm_files($full_dest);
	make_symlink_raw_target($src, $full_dest);
}

# _expand_path expands all path "." and ".." components, but doesn't
# resolve symbolic links.
sub _expand_path {
	my $start = @_ ? shift : '.';
	my @pathname = split(m:/+:,$start);
	my @respath;
	for my $entry (@pathname) {
		if ($entry eq '.' || $entry eq '') {
			# Do nothing
		}
		elsif ($entry eq '..') {
			if ($#respath == -1) {
				# Do nothing
			}
			else {
				pop @respath;
			}
		}
		else {
			push @respath, $entry;
		}
	}

	my $result;
	for my $entry (@respath) {
		$result .= '/' . $entry;
	}
	if (! defined $result) {
		$result="/"; # special case
	}
	return $result;
}

# Checks if make's jobserver is enabled via MAKEFLAGS, but
# the FD used to communicate with it is actually not available.
sub is_make_jobserver_unavailable {
	if (exists $ENV{MAKEFLAGS} && 
	    $ENV{MAKEFLAGS} =~ /(?:^|\s)--jobserver-(?:fds|auth)=(\d+)/) {
		if (!open(my $in, "<&$1")) {
			return 1; # unavailable
		}
		else {
			close $in;
			return 0; # available
		}
	}

	return; # no jobserver specified
}

# Cleans out jobserver options from MAKEFLAGS.
sub clean_jobserver_makeflags {
	if (exists $ENV{MAKEFLAGS}) {
		if ($ENV{MAKEFLAGS} =~ /(?:^|\s)--jobserver-(?:fds|auth)=\d+/) {
			$ENV{MAKEFLAGS} =~ s/(?:^|\s)--jobserver-(?:fds|auth)=\S+//g;
			$ENV{MAKEFLAGS} =~ s/(?:^|\s)-j\b//g;
		}
		delete $ENV{MAKEFLAGS} if $ENV{MAKEFLAGS} =~ /^\s*$/;
	}
}

# If cross-compiling, returns appropriate cross version of command.
sub cross_command {
	my ($package, $command) = @_;
	if (package_cross_type($package) eq 'target') {
		if (dpkg_architecture_value("DEB_HOST_GNU_TYPE") ne dpkg_architecture_value("DEB_TARGET_GNU_TYPE")) {
			return dpkg_architecture_value("DEB_TARGET_GNU_TYPE") . "-$command";
		}
	}
	if (is_cross_compiling()) {
		return dpkg_architecture_value("DEB_HOST_GNU_TYPE")."-$command";
	}
	else {
		return $command;
	}
}

# Returns the SOURCE_DATE_EPOCH ENV variable if set OR computes it
# from the latest changelog entry, sets the SOURCE_DATE_EPOCH ENV
# variable and returns the computed value.
sub get_source_date_epoch {
	return $ENV{SOURCE_DATE_EPOCH} if exists($ENV{SOURCE_DATE_EPOCH});
	_parse_non_binnmu_date_epoch();
	return $ENV{SOURCE_DATE_EPOCH};
}

{
	my $_non_binnmu_date_epoch;

	# Needed for dh_strip_nondeterminism - not exported by default because it is not likely
	# to be useful beyond that one helper.
	sub get_non_binnmu_date_epoch {
		return $_non_binnmu_date_epoch if defined($_non_binnmu_date_epoch);
		_parse_non_binnmu_date_epoch();
		return $_non_binnmu_date_epoch;
	}

	sub _parse_non_binnmu_date_epoch {
		eval { require Dpkg::Changelog::Debian };
		if ($@) {
			warning "unable to set SOURCE_DATE_EPOCH: $@";
			return;
		}
		eval { require Time::Piece };
		if ($@) {
			warning "unable to set SOURCE_DATE_EPOCH: $@";
			return;
		}

		my $changelog = Dpkg::Changelog::Debian->new(range => {"count" => 2});
		$changelog->load("debian/changelog");

		my $first_entry = $changelog->[0];
		my $non_binnmu_entry = $first_entry;
		my $optional_fields = $first_entry->get_optional_fields();
		my $first_tt = $first_entry->get_timestamp();
		$first_tt =~ s/\s*\([^\)]+\)\s*$//; # Remove the optional timezone codename
		my $first_timestamp = Time::Piece->strptime($first_tt, "%a, %d %b %Y %T %z")->epoch;
		my $non_binnmu_timestamp = $first_timestamp;
		if (exists($optional_fields->{'Binary-Only'}) and lc($optional_fields->{'Binary-Only'}) eq 'yes') {
			$non_binnmu_entry = $changelog->[1];
			my $non_binnmu_options = $non_binnmu_entry->get_optional_fields();
			if (exists($non_binnmu_options->{'Binary-Only'}) and lc($non_binnmu_options->{'Binary-Only'}) eq 'yes') {
				error("internal error: Could not locate the first non-binnmu entry in the change (assumed it would be the second entry)");
			}
			my $non_binnmu_tt = $non_binnmu_entry->get_timestamp();
			$non_binnmu_tt =~ s/\s*\([^\)]+\)\s*$//; # Remove the optional timezone codename
			$non_binnmu_timestamp = Time::Piece->strptime($non_binnmu_tt, "%a, %d %b %Y %T %z")->epoch();
		}

		$ENV{SOURCE_DATE_EPOCH} = $first_timestamp if not exists($ENV{SOURCE_DATE_EPOCH});
		$_non_binnmu_date_epoch = $non_binnmu_timestamp;
		return;
	}
}

# Setup the build ENV by setting dpkg-buildflags (via set_buildflags()) plus
# cleaning up HOME (etc) in compat 13+
sub setup_buildenv {
	set_buildflags();
	if (not compat(12)) {
		setup_home_and_xdg_dirs();
	}
}

sub setup_home_and_xdg_dirs {
	require Cwd;
	my $cwd = Cwd::getcwd();
	my $home_dir = join('/', $cwd, generated_file('_source', 'home', 0));
	my @paths = (
		$home_dir,
	);
	my @clear_env = qw(
		XDG_CACHE_HOME
		XDG_CONFIG_DIRS
		XDG_CONFIG_HOME
		XDG_DATA_HOME
		XDG_DATA_DIRS
		XDG_RUNTIME_DIR
	);
	mkdirs(@paths);
	for my $envname (@clear_env) {
		delete($ENV{$envname});
	}
	$ENV{'HOME'} = $home_dir;
	return;
}

sub reset_buildflags {
	eval { require Dpkg::BuildFlags };
	if ($@) {
		warning "unable to load build flags: $@";
		return;
	}
	delete($ENV{'DH_INTERNAL_BUILDFLAGS'});
	my $buildflags = Dpkg::BuildFlags->new();
	foreach my $flag ($buildflags->list()) {
		next unless $flag =~ /^[A-Z]/; # Skip flags starting with lowercase
		delete($ENV{$flag});
	}
}

# Sets environment variables from dpkg-buildflags. Avoids changing
# any existing environment variables.
sub set_buildflags {
	return if $ENV{DH_INTERNAL_BUILDFLAGS};
	$ENV{DH_INTERNAL_BUILDFLAGS}=1;

	# For the side effect of computing the SOURCE_DATE_EPOCH variable.
	get_source_date_epoch();

	return if compat(8);

	# Export PERL_USE_UNSAFE_INC as a transitional step to allow us
	# to remove . from @INC by default without breaking packages which
	# rely on this [CVE-2016-1238]
	$ENV{PERL_USE_UNSAFE_INC} = 1 if compat(10);

	eval { require Dpkg::BuildFlags };
	if ($@) {
		warning "unable to load build flags: $@";
		return;
	}

	my $buildflags = Dpkg::BuildFlags->new();
	$buildflags->load_config();
	foreach my $flag ($buildflags->list()) {
		next unless $flag =~ /^[A-Z]/; # Skip flags starting with lowercase
		if (! exists $ENV{$flag}) {
			$ENV{$flag} = $buildflags->get($flag);
		}
	}
}

# Gets a DEB_BUILD_OPTIONS option, if set.
sub get_buildoption {
	my ($wanted, $default) = @_;

	return $default if not exists($ENV{DEB_BUILD_OPTIONS});

	foreach my $opt (split(/\s+/, $ENV{DEB_BUILD_OPTIONS})) {
		# currently parallel= is the only one with a parameter
		if ($opt =~ /^parallel=(-?\d+)$/ && $wanted eq 'parallel') {
			return $1;
		} elsif ($opt =~ m/^dherroron=(\S*)$/ && $wanted eq 'dherroron') {
			my $value = $1;
			if ($value ne 'obsolete-compat-levels') {
				warning("Unknown value \"${value}\" as parameter for \"dherroron\" seen in DEB_BUILD_OPTIONS");
			}
			return $value;
		} elsif ($opt eq $wanted) {
			return 1;
		}
	}
	return $default;
}

# Returns true if DEB_BUILD_PROFILES lists the given profile.
sub is_build_profile_active {
	my ($wanted) = @_;
	return 0 if not exists($ENV{DEB_BUILD_PROFILES});
	for my $prof (split(m/\s+/, $ENV{DEB_BUILD_PROFILES})) {
		return 1 if $prof eq $wanted;
	}
	return 0;
}


# Called when an executable config file failed.  It provides a more helpful error message in
# some cases (especially when the file was not intended to be executable).
sub _executable_dh_config_file_failed {
	my ($source, $err, $proc_err) = @_;
	error("Error closing fd/process for ${source}: $err") if $err;
	# The interpreter did not like the file for some reason.
	# Lets check if the maintainer intended it to be
	# executable.
	if (not is_so_or_exec_elf_file($source) and not _has_shebang_line($source)) {
		warning("${source} is marked executable but does not appear to an executable config.");
		warning();
		warning("If ${source} is intended to be an executable config file, please ensure it can");
		warning("be run as a stand-alone script/program (e.g. \"./${source}\")");
		warning("Otherwise, please remove the executable bit from the file (e.g. chmod -x \"${source}\")");
		warning();
		warning('Please see "Executable debhelper config files" in debhelper(7) for more information.');
		warning();
	}
	$? = $proc_err;
	error_exitcode("${source} (executable config)");
	return;
}


# install a dh config file (e.g. debian/<pkg>.lintian-overrides) into
# the package.  Under compat 9+ it may execute the file and use its
# output instead.
#
# install_dh_config_file(SOURCE, TARGET)
sub install_dh_config_file {
	my ($source, $target) = @_;

	if (!compat(8) and -x $source) {
		my @sstat = stat(_) || error("cannot stat $source: $!");
		open(my $tfd, '>', $target) || error("cannot open $target: $!");
		chmod(0644, $tfd) || error("cannot chmod $target: $!");
		open(my $sfd, '-|', $source) || error("cannot run $source: $!");
		while (my $line = <$sfd>) {
			print ${tfd} $line;
		}
		if (!close($sfd)) {
			_executable_dh_config_file_failed($source, $!, $?);
		}
		close($tfd) || error("cannot close $target: $!");
		# Set the mtime (and atime) to ensure reproducibility.
		utime($sstat[9], $sstat[9], $target);
	} else {
		install_file($source, $target);
	}
	return 1;
}

sub restore_file_on_clean {
	my ($file) = @_;
	my $bucket_index = 'debian/.debhelper/bucket/index';
	my $bucket_dir = 'debian/.debhelper/bucket/files';
	my $checksum;
	mkdirs($bucket_dir);
	if ($file =~ m{^/}) {
		error("restore_file_on_clean requires a path relative to the package dir");
	}
	$file =~ s{^\./}{}g;
	$file =~ s{//++}{}g;
	if ($file =~ m{^\.} or $file =~ m{/CVS/} or $file =~ m{/\.}) {
		# We do not want to smash a Vcs repository by accident.
		warning("Attempt to store $file, which looks like a VCS file or");
		warning("a hidden package file (like quilt's \".pc\" directory)");
		error("This tool probably contains a bug.");
	}
	if (-l $file or not -f _) {
		error("Cannot store $file: Can only store regular files (no symlinks, etc.)");
	}
	require Digest::SHA;

	$checksum = Digest::SHA->new('256')->addfile($file, 'b')->hexdigest;

	if (not $dh{NO_ACT}) {
		my ($in_index);
		open(my $fd, '+>>', $bucket_index)
			or error("open($bucket_index, a+) failed: $!");
		seek($fd, 0, 0);
		while (my $line = <$fd>) {
			my ($cs, $stored_file);
			chomp($line);
			($cs, $stored_file) = split(m/ /, $line, 2);
			next if ($stored_file ne $file);
			$in_index = 1;
		}
		if (not $in_index) {
			# Copy and then rename so we always have the full copy of
			# the file in the correct place (if any at all).
			doit('cp', '-an', '--reflink=auto', $file, "${bucket_dir}/${checksum}.tmp");
			rename_path("${bucket_dir}/${checksum}.tmp", "${bucket_dir}/${checksum}");
			print {$fd} "${checksum} ${file}\n";
		}
		close($fd) or error("close($bucket_index) failed: $!");
	}

	return 1;
}

sub restore_all_files {
	my ($clear_index) = @_;
	my $bucket_index = 'debian/.debhelper/bucket/index';
	my $bucket_dir = 'debian/.debhelper/bucket/files';

	return if not -f $bucket_index;
	open(my $fd, '<', $bucket_index)
		or error("open($bucket_index) failed: $!");

	while (my $line = <$fd>) {
		my ($cs, $stored_file, $bucket_file);
		chomp($line);
		($cs, $stored_file) = split(m/ /, $line, 2);
		$bucket_file = "${bucket_dir}/${cs}";
		# Restore by copy and then rename.  This ensures that:
		# 1) If dh_clean is interrupted, we can always do a full restore again
		#    (otherwise, we would be missing some of the files and have to handle
		#     that with scary warnings)
		# 2) The file is always fully restored or in its "pre-restore" state.
		doit('cp', '-an', '--reflink=auto', $bucket_file, "${bucket_file}.tmp");
		rename_path("${bucket_file}.tmp", $stored_file);
	}
	close($fd);
	rm_files($bucket_index) if $clear_index;
	return;
}

sub open_gz {
	my ($file) = @_;
	my $fd;
	eval {
		require PerlIO::gzip;
	};
	if ($@) {
		open($fd, '-|', 'gzip', '-dc', $file)
		  or error("gzip -dc $file failed: $!");
	} else {
		# Pass ":unix" as well due to https://rt.cpan.org/Public/Bug/Display.html?id=114557
		# Alternatively, we could ensure we always use "POSIX::_exit".  Unfortunately,
		# loading POSIX is insanely slow.
		open($fd, '<:unix:gzip', $file)
		  or error("open $file [<:unix:gzip] failed: $!");
	}
	return $fd;
}

sub deprecated_functionality {
	my ($warning_msg, $compat_removal, $removal_msg) = @_;
	if (defined($compat_removal) and not compat($compat_removal - 1)) {
		my $msg = $removal_msg // $warning_msg;
		warning($msg);
		error("This feature was removed in compat ${compat_removal}.");
	} else {
		warning($warning_msg);
		warning("This feature will be removed in compat ${compat_removal}.")
		  if defined($compat_removal);
	}
	return 1;
}

sub log_installed_files {
	my ($package, @patterns) = @_;

	return if $dh{NO_ACT};
	my $tool = $TOOL_NAME;
	if (ref($package) eq 'HASH') {
		my $options = $package;
		$tool = $options->{'tool_name'} // error('Missing mandatory "tool_name" option for log_installed_files');
		$package = $options->{'package'} // error('Missing mandatory "package" option for log_installed_files');
	}

	my $log = generated_file($package, 'installed-by-' . $tool);
	open(my $fh, '>>', $log) or error("open $log: $!");
	for my $src (@patterns) {
		print $fh "$src\n";
	}
	close($fh) or error("close $log: $!");

	return 1;
}

use constant {
	# The ELF header is at least 0x32 bytes (32bit); any filer shorter than that is not an ELF file
	ELF_MIN_LENGTH => 0x32,
	ELF_MAGIC => "\x7FELF",
	ELF_ENDIAN_LE => 0x01,
	ELF_ENDIAN_BE => 0x02,
	ELF_TYPE_EXECUTABLE => 0x0002,
	ELF_TYPE_SHARED_OBJECT => 0x0003,
};

sub is_so_or_exec_elf_file {
	my ($file) = @_;
	open(my $fd, '<:raw', $file) or error("open $file: $!");
	my $buflen = 0;
	my ($buf, $endian);
	while ($buflen < ELF_MIN_LENGTH) {
		my $r = read($fd, $buf, ELF_MIN_LENGTH - $buflen, $buflen) // error("read ($file): $!");
		last if $r == 0; # EOF
		$buflen += $r
	}
	close($fd);
	return 0 if $buflen < ELF_MIN_LENGTH;

	return 0 if substr($buf, 0x00, 4) ne ELF_MAGIC;
	$endian = unpack('c', substr($buf, 0x05, 1));
	my ($long_format, $short_format);

	if ($endian == ELF_ENDIAN_BE) {
		$long_format = 'N';
		$short_format = 'n';
	} elsif ($endian == ELF_ENDIAN_LE) {
		$long_format = 'V';
		$short_format = 'v';
	} else {
		return 0;
	}
	my $elf_version = substr($buf, 0x14, 4);
	my $elf_type = substr($buf, 0x10, 2);


	return 0 if unpack($long_format, $elf_version) != 0x00000001;
	my $elf_type_unpacked = unpack($short_format, $elf_type);
	return 0 if $elf_type_unpacked != ELF_TYPE_EXECUTABLE and $elf_type_unpacked != ELF_TYPE_SHARED_OBJECT;
	return 1;
}

sub _has_shebang_line {
	my ($file) = @_;
	open(my $fd, '<', $file) or error("open $file: $!");
	my $line = <$fd>;
	close($fd);
	return 1 if (defined($line) and substr($line, 0, 2) eq '#!');
	return 0;
}

# Returns true iff the given argument is an empty directory.
# Corner-cases:
#  - false if not a directory
sub is_empty_dir {
	my ($dir) = @_;
	return 0 if not -d $dir;
	my $ret = 1;
	opendir(my $dir_fd, $dir) or error("opendir($dir) failed: $!");
	while (defined(my $entry = readdir($dir_fd))) {
		next if $entry eq '.' or $entry eq '..';
		$ret = 0;
		last;
	}
	closedir($dir_fd);
	return $ret;
}

sub on_pkgs_in_parallel(&) {
	unshift(@_, $dh{DOPACKAGES});
	goto \&on_items_in_parallel;
}

# Given a list of files, find all hardlinked files and return:
# 1: a list of unique files (all files in the list are not hardlinked with any other file in that list)
# 2: a map where the keys are names of hardlinks and the value points to the name selected as the file put in the
#    list of unique files.
#
# This is can be used to relink hard links after modifying one of them.
sub find_hardlinks {
	my (@all_files) = @_;
	my (%seen, %hardlinks, @unique_files);
	for my $file (@all_files) {
		my ($dev, $inode, undef, $nlink)=stat($file);
		if (defined $nlink && $nlink > 1) {
			if (! $seen{"$inode.$dev"}) {
				$seen{"$inode.$dev"}=$file;
				push(@unique_files, $file);
			} else {
				# This is a hardlink.
				$hardlinks{$file}=$seen{"$inode.$dev"};
			}
		} else {
			push(@unique_files, $file);
		}
	}
	return (\@unique_files, \%hardlinks);
}

sub on_items_in_parallel {
	my ($pkgs_ref, $code) = @_;
	my @pkgs = @{$pkgs_ref};
	my %pids;
	my $parallel = $MAX_PROCS;
	my $count_per_proc = int( (scalar(@pkgs) + $parallel - 1)/ $parallel);
	my $exit = 0;
	if ($count_per_proc < 1) {
		$count_per_proc = 1;
		if (@pkgs > 3) {
			# Forking has a considerable overhead, so bulk the number
			# a bit.  We do not do this unconditionally, because we
			# want parallel issues (if any) to appear already with 2
			# packages and two procs (because people are lazy when
			# testing).
			#
			# Same reason for also unconditionally forking with 1 pkg
			# in 1 proc.
			$count_per_proc = 2;
		}
	}
	# Assertion, $count_per_proc * $parallel >= scalar(@pkgs)
	while (@pkgs) {
		my @batch = splice(@pkgs, 0, $count_per_proc);
		my $pid = fork() // error("fork: $!");
		if (not $pid) {
			# Child processes should not write to the log file
			inhibit_log();
			eval {
				$code->(@batch);
			};
			if (my $err = $@) {
				$err =~ s/\n$//;
				print STDERR "$err\n";
				exit(2);
			}
			exit(0);
		}
		$pids{$pid} = 1;
	}
	while (%pids) {
		my $pid = wait;
		error("wait() failed: $!") if $pid == -1;
		delete($pids{$pid});
		if ($? != 0) {
			$exit = 1;
		}
	}
	if ($exit) {
		error("Aborting due to earlier error");
	}
	return;
}

*on_selected_pkgs_in_parallel = \&on_items_in_parallel;

sub compute_doc_main_package {
	my ($doc_package) = @_;
	# if explicitly set, then choose that.
	return $dh{DOC_MAIN_PACKAGE} if $dh{DOC_MAIN_PACKAGE};
	# In compat 10 (and earlier), there is no auto-detection
	return $doc_package if compat(10);
	my $target_package = $doc_package;
	# If it is not a -doc package, then docs should be installed
	# under its own package name.
	return $doc_package if $target_package !~ s/-doc$//;
	# FOO-doc hosts the docs for FOO; seems reasonable
	return $target_package if exists($package_fields{$target_package});
	if ($doc_package =~ m/^lib./) {
		# Special case, "libFOO-doc" can host docs for "libFOO-dev"
		my $lib_dev = "${target_package}-dev";
		return $lib_dev if exists($package_fields{$lib_dev});
		# Technically, we could go look for a libFOO<something>-dev,
		# but atm. it is presumed to be that much of a corner case
		# that it warrents an override.
	}
	# We do not know; make that clear to the caller
	return;
}

sub dbgsym_tmpdir {
	my ($package) = @_;
	return "debian/.debhelper/${package}/dbgsym-root";
}

sub perl_cross_incdir {
	return if !is_cross_compiling();

	# native builds don't currently need this so only load it on demand
	require Config; Config->import();

	my $triplet = dpkg_architecture_value("DEB_HOST_MULTIARCH");
	my $perl_version = $Config::Config{version};
	my $incdir = "/usr/lib/$triplet/perl/cross-config-${perl_version}";
	return undef if !-e "$incdir/Config.pm";
	return $incdir;
}

sub is_known_package {
	my ($package) = @_;
	state %known_packages = map { $_ => 1 } getpackages();
	return 1 if exists($known_packages{$package});
	return 0
}

sub assert_opt_is_known_package {
	my ($package, $method) = @_;
	if (not is_known_package($package)) {
		error("Requested unknown package $package via $method, expected one of: " . join(' ', getpackages()));
	}
	return 1;
}


sub dh_gencontrol_automatic_substvars {
	my ($package, $substvars_file, $has_dbgsym) = @_;
	return if not -f $substvars_file;

	require Dpkg::Control;
	require Dpkg::Control::Fields;
	open(my $sfd, '+<', $substvars_file) or error("open $substvars_file: $!");
	my @dep_fields = Dpkg::Control::Fields::field_list_pkg_dep();
	my %known_dep_fields = map { lc($_) => 1 } @dep_fields;
	my (%field_vars, $needs_dbgsym);
	while (my $line = <$sfd>) {
		next if $line =~ m{^\s*(?:[#].*)?$};
		chomp($line);
		next if $line !~ m{(\w[-:0-9A-Za-z]*)([?!\$]?=)(?:.*)};
		my $key = $1;
		my $assignment = $2;
		# Ignore `$=` because they will work without us doing anything (which in turn means
		# we might not have to rewrite the file).
		if ($assignment eq '$=') {
			$needs_dbgsym = 1;
			next;
		}
		# If there is "required" substvar, then it will not be used for the dbgsym.
		$needs_dbgsym = 1 if $assignment eq '!=';
		next if ($key !~ m/:([-0-9A-Za-z]+)$/);
		my $field_name_lc = lc($1);
		next if not exists($known_dep_fields{$field_name_lc});
		my $substvar = '${' . $key . '}';
		push(@{$field_vars{$field_name_lc}}, $substvar);
	}
	close($sfd);
	return if not %field_vars and not $needs_dbgsym;

	open(my $ocfd, '<', 'debian/control') or error("open debian/control: $!");
	my $src_stanza = Dpkg::Control->new;
	my $pkg_stanza;
	$src_stanza->parse($ocfd, 'debian/control') or error("No source stanza!?");
	while (1) {
		$pkg_stanza = Dpkg::Control->new;
		$pkg_stanza->parse($ocfd, 'debian/control') // error("EOF before the ${package} stanza appeared!?");
		last if $pkg_stanza->{'Package'} eq $package;
	}
	close($ocfd);

	my $rewritten_dctrl = generated_file($package, "rewritten-dctrl");
	for my $field_name (@dep_fields) {
		my $field_name_lc = lc($field_name);
		# No merging required
		next if not exists($field_vars{$field_name_lc});
		my $field_value = $pkg_stanza->{$field_name};
		my $merge_value = join(", ", @{$field_vars{$field_name_lc}});
		if (defined($field_value) and $field_value !~ m{^\s*+$}) {
			$field_value =~ s/,\s*$//;
			$field_value .= ", ";
			$field_value .= $merge_value;
		} else {
			$field_value = $merge_value;
		}
		$pkg_stanza->{$field_name} = $field_value;
	}
	open(my $wfd, '>', $rewritten_dctrl) or error("open ${rewritten_dctrl}: $!");
	$src_stanza->output($wfd);
	print {$wfd} "\n";
	$pkg_stanza->output($wfd);
	if ($has_dbgsym) {
		my $dbgsym_stanza = Dpkg::Control->new;
		# Minimal stanza to avoid substvars warnings. Most fields are still set
		# via -D.
		$dbgsym_stanza->{'Package'} = "${package}-dbgsym";
		$dbgsym_stanza->{'Architecture'} = $pkg_stanza->{"Architecture"};
		$dbgsym_stanza->{'Description'} = "debug symbols for ${package}";
		print {$wfd} "\n";
		$dbgsym_stanza->output($wfd);
	}
	close($wfd) or error("Failed to close/flush ${rewritten_dctrl}: $!");
	return ($rewritten_dctrl, $has_dbgsym);
}


sub _internal_optional_file_args {
	state $_disable_file_seccomp;
	if (not defined($_disable_file_seccomp)) {
		my $consider_disabling_seccomp = 0;
		if ($ENV{'FAKEROOTKEY'} or ($ENV{'LD_PRELOAD'} // '') =~ m/fakeroot/) {
			$consider_disabling_seccomp = 1;
		}
		if ($consider_disabling_seccomp) {
			my $has_no_sandbox = (qx_cmd('file', '--help') // '') =~ m/--no-sandbox/;
			$consider_disabling_seccomp = 0 if not $has_no_sandbox;
		}
		$_disable_file_seccomp = $consider_disabling_seccomp;
	}
	return('--no-sandbox') if $_disable_file_seccomp;
	return;
}

sub assert_unsafe_execution_is_ok {
	if (not $Debian::Debhelper::Dh_Lib::ALLOW_UNSAFE_EXECUTION) {
		error("Internal error: The command did not want to allow unsafe execution, but was about to trigger it!");
	}
}

1
