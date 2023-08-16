#!/usr/bin/perl

my $file;
my $ignore_ws   = 1;
my $ignore_case = 0;

my $usage = << "ENDOFUSAGE";
Usage: $0 [FILE] [OPTION]...
Print only unique lines (comments and empty lines are ignored).
With no FILE, read standard input.

    -w, --preserve-ws   Do not ignore white-space characters when comparing

    -h, --help          Print help
ENDOFUSAGE

use strict;
use warnings;

while (scalar @ARGV) {
    my $str = shift @ARGV;
    if ($str =~ /^-./) {
        $ignore_ws   = 0 if $str eq "-w" || $str eq "--preserve-ws";
        die $usage       if $str eq "-h" || $str eq "--help";
        next;   
    }
    $file = $str;
}

my $file_header;
my @cases;

unshift @ARGV, $file if defined $file;

{
    while (<>) {
        last unless ($_ =~ /\/\/.*$|^\s*$/); #skip comments/empty lines
    }
    chomp;
    $file_header = $_;
        
    my %seen;
    while (<>) {
        chomp;
        next if ($_ =~ /\/\/.*$|^\s*$/); #skip comments/empty lines

        my $str = $_;
        if ($ignore_ws) {
            s/^\s+|\s+$//g;
            s/\s+/ /g;
        }
        $_ = lc if $ignore_case;

        next if $seen{$_}++;             #skip duplicate lines
        push @cases, $str;
    }
}

print "$file_header\n";
print "$_\n" for @cases;
