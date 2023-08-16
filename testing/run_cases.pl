#!/usr/bin/perl

use strict;
use warnings;
use List::Util qw[min max];
use File::Spec::Functions;

my $out_dir = ".";
my $strict = 0; #stop on first failures
my $exit_code = 0;

my $usage = << "ENDOFUSAGE";
Usage:
    $0 <cases_file> [app_options]
    $0 [options] -- <cases_file> [app_options]

    In first form <cases_file> name couldn't start with '-' symbol.
    Filename '-' is reserved for STDIN for both forms.

    -s                    stop on first failure

    -a <exe>              test app (creates preprocessor config file)

    -o <out_dir>          output directory for logs

    -h, --help            print help
ENDOFUSAGE

my $app = $ENV{'SHISA'} . "\\bin\\conv_test.exe";

while (scalar @ARGV) {
    my $str = shift @ARGV;
    if ($str =~ /^-./)   {
        $app           =     shift @ARGV if $str eq "-a";     # test app
        $out_dir       =     shift @ARGV if $str eq "-o";
        $strict        =  1  if $str eq "-s";
        die $usage           if $str eq "-h" || $str eq "--help";
        last                 if $str eq "--";
        next;
    }
    unshift @ARGV, $str;
    last;
}

unless(-e $out_dir and -d $out_dir) {
    mkdir $out_dir or die "Unable to create directory $out_dir: $!";
}

my $handle;
if ($ARGV[0] eq "-") {
    $handle = *STDIN;
}
else {
    open $handle,  "<", $ARGV[0] or die "cannot open $ARGV[0]: $!";
}

shift @ARGV;
my $extra_options = join (' ', @ARGV);

my %configs = ();

while (<$handle>)  {
	last unless ($_ =~ /\/\/.*$|^\s*$/)			#skip comments/empty lines
};

chomp;
my @options = split /\s+-|^-/; 		#parse options
shift @options;   	#start on the first '-'
#add whitespace between the option and value for single caracter options only
# @options = map {s/^([^-])/$1 /;$_} @options;

#split option name and value on whitespace (for --opt we do not know where it ends and value begins otherwise)
	
my @option_keys   = map { "-".(split / /, $_)[0]  } @options;
my @defualt_vals  = map {	  (split / /, $_)[1]  } @options;

my $out_log  = catfile($out_dir, "output.log");
my $err_log  = catfile($out_dir, "error.log");
my $conf_log = catfile($out_dir, "configs.log");
my $conf_bare_log = catfile($out_dir, "configs_bare.log");
my $res_file      = catfile($out_dir, "results.log");
my $res_bare_file = catfile($out_dir, "results_bare.log");
open my $err_log_handle, ">>", "$err_log" or die "cannot open $err_log: $!";
open my $out_log_handle, ">>", "$out_log" or die "cannot open $out_log: $!";
open my $results_handle, ">>", "$res_file" or die "cannot open $res_file: $!";
open my $results_bare_handle,  ">>", "$res_bare_file" or die "cannot open $res_bare_file: $!";

my $i = 0;
while (<$handle> ) {
	chomp;
    do {
        $i++;		
		s/^\s+//;
		s/\s+$//;
		my @vals = split /\s+/;
		my $cur_options = join ( ' ', 
			 map {$_ <= $#vals ? $option_keys[$_]." ".$vals[$_] : 
								 $option_keys[$_]." ".$defualt_vals[$_]} 0..$#defualt_vals);

        my $test = "[case # $i]\n$app $cur_options $extra_options";
		print "$test\n";
		my @log = qx "$app $cur_options $extra_options 2>&1";
        print {$out_log_handle} "$test\n@log";
        if ((scalar grep {/FAILED/} @log) != 0) {
            print {$err_log_handle} "$test\n@log";
            $exit_code = 1;
            last if $strict;
        }

        # my @times   = map {s/DBG: time gui\s+(\d+).*/$1/; $_} grep {/DBG: time gui/} @log;
        # @times = @times[1000..$#times] if scalar @times; # skip timed run with find
        # push @times, -1 if not scalar @times;
        # my $mean 	= 0;
		# map {$mean += $_} @times;
		# $mean /= scalar @times;
        # my $stddev 	= 0;
		# if ((scalar @times) > 1) {
		# 	map {$stddev += ($_ - $mean) * ($_ - $mean)} @times;
		# 	$stddev = sqrt ($stddev / ((scalar @times) - 1));
		# }
        # my $min 	= min @times;
        # my $max 	= max @times;

        # my $out 	= 	sprintf "%.0f \t(%.0f - %.0f) \t%.0f \t%.4f \t(%.0f - %.0f) ", 
		# 	            $mean,$mean-1.96*$stddev/sqrt(@times),$mean+1.96*$stddev/sqrt(@times), 
		# 				$stddev, $stddev/$mean,$min, $max;
        # my @selected = map {s/.*Chosen Algorithm: ([\w\d]+).*/$1/; $_} grep {/Chosen Algorithm:/} @log;
        # my $result = $out . scalar(@times) . " " . join ("\n", map {"$selected[$_]"} 0..$#selected);

        my @dir = map {s/.*stats: (\w+).*\n/$1/; $_} grep {/stats: (\w+)-/} @log;
        my @times = map {s/.*GPU Kernel Time .*Elapsed: (\d+.\d+).*\n/$1/; $_} grep {/GPU Kernel Time/} @log;
        my @solvers = map {s/.*Solution: (\d+)\/([\w\d]+).*\n/$1\/$2/; $_} grep {/Algorithm: \d+, Solution:/} @log;
        my $out = join("\n", map { "$times[$_]\t$dir[$_]\t$solvers[$_]" } (0 .. $#solvers)) . "\n";
        print {$results_handle} "$test\n$out";
        print {$results_bare_handle} $out;
		print $out;

        if (exists $ENV{SP3_PREPROCESSOR_CONFIG_FILE}) {
            local $/;
            my $sp3_conf_file = $ENV{SP3_PREPROCESSOR_CONFIG_FILE};
            open my $fh, '<', $sp3_conf_file or die "can't open $sp3_conf_file: $!";
            my $config = <$fh>;

            if (exists $configs{$config}) {
               push @{$configs{$config}}, $cur_options." ".$extra_options;
            }
            else {
               $configs{$config} = [$cur_options." ".$extra_options];
            }    
        }             
	} unless ($_ =~ /\/\/.*$|^\s*$/);		 #skip comments/empty lines
};

foreach my $config (keys %configs) {
		qx "echo $config >> $conf_bare_log";
		qx "echo $config >> $conf_log";
        for my $options ( @{$configs{$config}}) {
            qx "echo \t$options >> $conf_log";
        };      
};

my $exit_str = ($exit_code ? "FAIL" : "SUCCESS") . ": run_cases.pl exit code: $exit_code";
print $exit_str;
print {$out_log_handle} $exit_str;
exit $exit_code;