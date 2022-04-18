#!/usr/bin/perl

my $usage = << "ENDOFUSAGE";
Usage: $0 -p /path/to/preconfigured -o /output/path [options]

Assemble preconfigured winograd shaders.
    -p <dir>        preconfigured shader
    -o <dir>        output dir
    -c              clean tmp files (gas source, code object etc.)
    -h, --help      Print help

ENDOFUSAGE

use strict;
use warnings;
use File::Copy;
use File::Basename;
use File::Compare;
use autodie qw(:all);

my $header = << "ENDOFHEADER";
/*******************************************************************************
 *
 * MIT License
 *
 * Copyright (c) 2022 Advanced Micro Devices, Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 *******************************************************************************/
ENDOFHEADER

my $clang="/opt/rocm/llvm/bin/clang";
my $objdump="/opt/rocm/llvm/bin/llvm-objdump";
my $out_dir="";
my $src_dir="";
my $clean=0;
my $xform_3_2=0;
my $strict=1;

while (scalar @ARGV) {
    my $str = shift @ARGV;
    if ($str =~ /^-./)   {
        $out_dir    =     shift @ARGV if $str eq "-o";
        $src_dir    =     shift @ARGV if $str eq "-p";
        $clean      =     1 if $str eq "-c";
        $strict     =     0 if $str eq "-no-strict";
        die $usage          if $str eq "-h" || $str eq "--help";
        next;
    }
}

die "$usage\nERROR: No output dir specified. Use -o option.\n" unless defined $out_dir;
die "$usage\nERROR: No input dir specified. Use -p option.\n" unless defined $src_dir;
die "Unable to execute clang($clang): $!\n" unless -e -X $clang;
die "Unable to read $src_dir: $!\n" unless -e -r $src_dir;

qx "mkdir -p $out_dir";

my @sources = <$src_dir/*>;
foreach my $src_path (@sources) {
    if ($src_path =~ /\.sp3$/) {

        my $group = 0;
        my $mcpu = "";
        my $file_name = basename($src_path);
        my $prefix = "";

        if ($file_name =~ /VEGA20/) {
            $mcpu = "gfx906";
            $file_name =~ s/VEGA20//;
            $prefix = "gfx9";
        }
        elsif ($file_name =~ /MI200/) {
            $mcpu = "gfx90a";
            $file_name =~ s/MI200//;
            $prefix = "gfx90a";
        }
        elsif ($file_name =~ /NAVI14/) {
            $mcpu = "gfx1030";
            $file_name =~ s/NAVI14//;
            $prefix = "gfx10";
        }
        else {
            die "Unknown asic\n";
        }

        if ($file_name =~ /_f3x2/) {
            $file_name =~ s/_f3x2//;
            $prefix .= "_f3x2";
        }

        $file_name = $prefix . $file_name;

        if ($file_name =~ /_group/) {
            $file_name =~ s/_group//;
            $group = 1;
        }

        $file_name = "Conv_Winograd_v21_1_3_$file_name";
        $file_name =~ s/dot2/_dot2/;
        $file_name =~ s/ostride/stride/;
        $file_name =~ s/dstride/dilation/;
        $file_name =~ s/pk/_pk/;
        $file_name =~ s/\.sp3/_group\.sp3/ if ($group != 0);
        $file_name =~ s/\.sp3/\.tmp\.s/;
        my $gas_filepath = "$out_dir/$file_name";

        #convert to gas file
        my @gaslines;
        open(my $handle, "<$src_path") || die "Unable to read to configured sp3 file($src_path): $!\n";
        while (<$handle>) {
            if (/\/\/ 00.*/) {
                chomp;
                s/.*:\s*//;
                s/ /, 0x/g;
                s/(.*)/.long 0x$1\n/;
                push @gaslines, $_;
            }
        }
        close($handle);
        open($handle, ">$gas_filepath") || die "Unable to write to temp gas file($gas_filepath): $!\n";
        print $handle @gaslines;
        close($handle);
        print "-- asic:                     $mcpu\n";
        print "-- write gas file:           $file_name\n";

        $file_name =~ s/\.tmp\.s/\.co/;
        my $co_filepath = "$out_dir/$file_name";

        #compile gas file to co
        my $cmd = "$clang -x assembler -mcumode -mwavefrontsize64 -target amdgcn--amdhsa -mcpu=$mcpu:sramecc-:xnack- $gas_filepath -o $co_filepath";
        print "$cmd\n";
        my $clang_stdout = qx "$cmd";
        print $clang_stdout;
        die "\nClang error code $?\n" if ($? != 0);
        print "-- write code object:        $file_name\n";

        $file_name =~ s/\.co/\.inc/;
        my $disasm_filename = "$file_name";
        my $disasm_filepath = "$out_dir/$disasm_filename";

        #disassemble code object
        open(my $fh, '>', $disasm_filepath) or die "Could not open file '$disasm_filepath' $!";
        say $fh $header;
        close($fh);

        $cmd = "$objdump --mattr=-WavefrontSize32,+WavefrontSize64,-xnack,+vop3p,+pk-fmac-f16-inst --mcpu=$mcpu --disassemble --no-leading-addr $co_filepath | sed \"s/\\s*\\/\\/.*//\" | sed \"s/^	//\" | tail +7 >> $disasm_filepath";
        qx "$cmd";
        
        print "-- write disasm file:        $file_name\n$cmd\n";

        $file_name =~ s/\.inc/\.disasm\.co/;
        my $disasm_co_filepath = "$out_dir/$file_name";

        #compile disassembled code object
        $cmd = "$clang -x assembler -mcumode -mwavefrontsize64 -target amdgcn--amdhsa -mcpu=$mcpu:sramecc-:xnack- $disasm_filepath -o $disasm_co_filepath";
        $clang_stdout = qx "$cmd";
        print $clang_stdout;
        die "\nClang error code $?\n" if ($? != 0);
        print "-- write disasm code object: $file_name\n";

        die "ERROR: Code object and disasm code object are not equals\n" if ($strict && compare($co_filepath, $disasm_co_filepath) != 0);
        qx "rm -f $gas_filepath $co_filepath $disasm_co_filepath" if ($clean != 0);

        print "\n";
    }
}

