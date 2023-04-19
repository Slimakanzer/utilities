#!/usr/bin/perl

my @files = ();

my $usage = << "ENDOFUSAGE";
Usage: $0 [OPTION]... [FILE]...
The tool concatenates headers and returns the Cartesian product of the input files.
With no FILE, or when FILE is -, read standard input.

    -h, --help      Print help
ENDOFUSAGE

use strict;
use warnings;

sub read_file;

while (scalar @ARGV) {
    my $str = shift @ARGV;
    if ($str =~ /^-./) {
        die $usage if $str eq "-h" || $str eq "--help";
        next;   
    }
    push @files, $str;
}

push @files, '-' if scalar @files eq 0;
die "Only single STDIN source '-' is allowed" if (scalar map { my $file = $files[$_]; $file eq '-' ? $file : () } 0..$#files) gt 1;

my $file = shift @files;
if ($file ne "-") {
    die "Cannot access file $file: $!" unless -e -r $file;
    push @ARGV, $file;
}
my ($file_header, @cases) = read_file;

while (scalar @files) {
    my $file = shift @files;
    if ($file ne "-") {
        die "Cannot access file $file: $!" unless -e -r $file;
        push @ARGV, $file;
    }
    my ($head, @lines) = read_file;

    $file_header .= " " . $head;
    @cases = map { my $case = $_; {map { $case . " " . $_} @lines;}} @cases;
}

print "$file_header\n";
print "$_\n" for @cases;

sub read_file {
    while (<>) {
        last unless ($_ =~ /\/\/.*$|^\s*$/)			#skip comments/empty lines
    }
    chomp;
    my $head = $_;
    
    my @lines;
    while (<>) {
        chomp;
        push @lines, $_ unless ($_ =~ /\/\/.*$|^\s*$/);		 #skip comments/empty lines
    }

    return ($head, @lines);
}