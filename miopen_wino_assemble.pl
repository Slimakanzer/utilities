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
 * Copyright (c) 2023 Advanced Micro Devices, Inc.
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

my $gfx10_quad_perm_workaround = << "ENDOFWORKAROUND";
.macro _v_pk_fmac_f16_gfx10_quad_perm vdst:req, vsrc0:req, vsrc1:req, q0:req, q1:req, q2:req, q3:req
    .long  0x780000FA + ((\\vdst << 17) + (\\vsrc1 << 9))
    .long  0xFF000000 + (\\vsrc0 + (\\q0 << 8) + (\\q1 << 10) + (\\q2 << 12) + (\\q3 << 14))
.endm
ENDOFWORKAROUND

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
        my $mcpu_config = "";
        my $file_name = basename($src_path);
        my $prefix = "";
        my $enable_gfx10_quad_perm_workaround = 0;

        if ($file_name =~ /VEGA20/) {
            next;
            $mcpu = "gfx90a";
            $file_name =~ s/VEGA20//;
            $prefix = "gfx9";
            $mcpu_config = ":sramecc+:xnack-";
        }
        elsif ($file_name =~ /NAVI21/) {
            $mcpu = "gfx1030";
            $file_name =~ s/NAVI21//;
            $prefix = "gfx10";
        }
        elsif ($file_name =~ /GFX11/) {
            next;
            $mcpu = "gfx1100";
            $file_name =~ s/GFX11//;
            $prefix = "gfx11";
        }
        else {
            die "Unknown asic\n";
        }

        $file_name = $prefix . $file_name;

        if ($file_name =~ /_group/) {
            $file_name =~ s/_group//;
            $group = 1;
        }

        $file_name = "Conv_Winograd_v30_2_6_$file_name";
        $file_name =~ s/dot2/_dot2/;
        $file_name =~ s/ostride/stride/;
        $file_name =~ s/dstride/dilation/;
        $file_name =~ s/pk/_pk/;
        $file_name =~ s/\.sp3/_group\.sp3/ if ($group != 0);
        $file_name =~ s/\.sp3/\.tmp\.s/;
        my $gas_filepath = "$out_dir/$file_name";

        $enable_gfx10_quad_perm_workaround = $file_name =~ /gfx10/ && $file_name =~ /fp16_dot2/;

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
        my $cmd = "$clang -x assembler -mcumode -mwavefrontsize64 -target amdgcn--amdhsa -mcpu=$mcpu$mcpu_config $gas_filepath -o $co_filepath";
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
        say $fh $gfx10_quad_perm_workaround if $enable_gfx10_quad_perm_workaround;

        $cmd = "$objdump --mattr=-WavefrontSize32,+WavefrontSize64,-xnack,+vop3p,+pk-fmac-f16-inst --mcpu=$mcpu --disassemble --no-leading-addr $co_filepath | sed \"s/\\s*\\/\\/.*//\" | sed \"s/^	//\" | tail +7";
        my $disasm_stdout = qx "$cmd";
        my @disasm_lines = split(/\n/, $disasm_stdout);

        my $i = 0;
        while ($i < $#disasm_lines) {
            if ($gfx10_quad_perm_workaround && $disasm_lines[$i] =~ /^.long/ && $disasm_lines[$i+1] =~ /^.long/) {
                my ($hex1_str) = $disasm_lines[$i]   =~ /.long\s+(0x[0-9a-f]+)/;
                my ($hex2_str) = $disasm_lines[$i+1] =~ /.long\s+(0x[0-9a-f]+)/;
                my $hex1 = hex $hex1_str;
                my $hex2 = hex $hex2_str;

                my $vdst  = ($hex1 & (255 << 17)) >> 17;
                my $vsrc1 = ($hex1 & (255 << 9)) >> 9;
                my $vsrc0 = ($hex2 & (255 << 0)) >> 0;
                my $q0    = ($hex2 & (3 << 8)) >> 8;
                my $q1    = ($hex2 & (3 << 10)) >> 10;
                my $q2    = ($hex2 & (3 << 12)) >> 12;
                my $q3    = ($hex2 & (3 << 14)) >> 14;
                # print "$hex1_str $hex1, $hex2_str $hex2 -- _v_pk_fmac_f16_gfx10_quad_perm $vdst, $vsrc0, $vsrc1, $q0, $q1, $q2, $q3";
                say $fh "_v_pk_fmac_f16_gfx10_quad_perm $vdst, $vsrc0, $vsrc1, $q0, $q1, $q2, $q3";

                $i += 2;
                next;
            }

            say $fh $disasm_lines[$i];
            $i++;
        }
        close($fh);
        
        print "-- write disasm file:        $file_name\n$cmd\n";

        $file_name =~ s/\.inc/\.disasm\.co/;
        my $disasm_co_filepath = "$out_dir/$file_name";

        #compile disassembled code object
        $cmd = "$clang -x assembler -mcumode -mwavefrontsize64 -target amdgcn--amdhsa -mcpu=$mcpu$mcpu_config $disasm_filepath -o $disasm_co_filepath";
        $clang_stdout = qx "$cmd";
        print $clang_stdout;
        die "\nClang error code $?\n" if ($? != 0);
        print "-- write disasm code object: $file_name\n";

        die "ERROR: Code object and disasm code object are not equals\n" if ($strict && compare($co_filepath, $disasm_co_filepath) != 0);
        qx "rm -f $gas_filepath $co_filepath $disasm_co_filepath" if ($clean != 0);

        print "\n";
    }
}

