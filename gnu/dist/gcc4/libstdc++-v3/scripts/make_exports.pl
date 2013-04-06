#!/usr/bin/perl -w

# This script takes two arguments, a version script and a dynamic library
# (in that order), and prints a list of symbols to be exported from the
# library.
# It expects a 'nm' with the POSIX '-P' option, but everyone has one of
# those, right?  It also expects that symbol names have a leading underscore,
# which is somewhat less likely.

use File::Glob ':glob';
use FileHandle;
use IPC::Open2;

# The glob patterns that are to be applied to the demangled name
my @cxx_globs = ();
# The glob patterns that apply directly to the name in the .o files
my @globs = ();
# The patterns for local variables (usually just '*').
my @ignored = ();

##########
# Fill in the various glob arrays.

# The next pattern will go into this array.
my $glob = \@globs;
my $symvers = shift;

open F,$symvers or die $!;

while (<F>) {
    chomp;
    # Lines of the form '} SOME_VERSION_NAME_1.0;'
    if (/^[ \t]*\}[ \tA-Z0-9_.a-z]*;[ \t]*$/) {
      $glob = \@globs;
      next;
    }
    # Comment and blank lines
    next if (/^[ \t]*\#/);
    next if (/^[ \t]*$/);
    # Lines of the form 'SOME_VERSION_NAME_1.1 {'
    next if (/^[A-Z0-9_. \t]*{$/);
    # Ignore 'global:'
    next if (/^[ \t]*global:$/);
    # After 'local:', globs should be ignored, they won't be exported.
    if (/^[ \t]*local:$/) {
	$glob = \@ignored;
	next;
    }
    # After 'extern "C++"', globs are C++ patterns
    if (/^[ \t]*extern \"C\+\+\"[ \t]*$/) {
	$glob = \@cxx_globs;
	next;
    }
    # Catch globs.  Note that '{}' is not allowed in globs by this script,
    # so only '*' and '[]' are available.
    if (/^[ \t]*([^ \t;{}#]+);?[ \t]*$/) {
	my $ptn = $1;
	# Turn the glob into a regex by replacing '*' with '.*'.
	$ptn =~ s/\*/\.\*/g;
	push @$glob,$ptn;
	next;
    }
    # Important sanity check.  This script can't handle lots of formats
    # that GNU ld can, so be sure to error out if one is seen!
    die "strange line `$_'";
}
close F;

# Make 'if (1)' for debugging.
if (0) {
    print "cxx:\n";
    (printf "%s\n",$_) foreach (@cxx_globs);
    print "globs:\n";
    (printf "%s\n", $_) foreach (@globs);
    print "ignored:\n";
    (printf "%s\n", $_) foreach (@ignored);
}

##########
# Combine the arrays into single regular expressions
# This cuts the time required from about 30 seconds to about 0.5 seconds.

my $glob_regex = '^_(' . (join '|',@globs) . ')$';
my $cxx_regex = (join '|',@cxx_globs);

##########
# Get all the symbols from the library, match them, and add them to a hash.

my %export_hash = ();
my $nm = $ENV{'NM_FOR_TARGET'} || "nm";
# Process each symbol.
print STDERR $nm.' -P '.(join ' ',@ARGV).'|';
open NM,$nm.' -P '.(join ' ',@ARGV).'|' or die $!;
# Talk to c++filt through a pair of file descriptors.
open2(*FILTIN, *FILTOUT, "c++filt --strip-underscores") or die $!;
NAME: while (<NM>) {
    my $i;
    chomp;

    # nm prints out stuff at the start, ignore it.
    next if (/^$/);
    next if (/:$/);
    # Ignore undefined and local symbols.
    next if (/^([^ ]+) [Ua-z] /);

    # $sym is the name of the symbol, $noeh_sym is the same thing with
    # any '.eh' suffix removed.
    die "unknown nm output $_" if (! /^([^ ]+) [A-Z] /);
    my $sym = $1;
    my $noeh_sym = $sym;
    $noeh_sym =~ s/\.eh$//;

    # Maybe it matches one of the patterns based on the symbol in the .o file.
    if ($noeh_sym =~ /$glob_regex/) {
        $export_hash{$sym} = 1;
	next NAME;
    }

    # No?  Well, maybe its demangled form matches one of those patterns.
    printf FILTOUT "%s\n",$noeh_sym;
    my $dem = <FILTIN>;
    chomp $dem;
    if ($dem =~ /$cxx_regex/) {
        $export_hash{$sym} = 2;
	next NAME;
    }

    # No?  Well, then ignore it.
}
close NM or die "nm error";
close FILTOUT or die "c++filt error";
close FILTIN or die "c++filt error";

##########
# Print out the export file

# Print information about generating this file
print "# This is a generated file.\n";
print "# It was generated by:\n";
printf "# %s %s %s\n", $0, $symvers, (join ' ',@ARGV);

foreach my $i (keys %export_hash) {
  printf "%s\n",$i or die;
}