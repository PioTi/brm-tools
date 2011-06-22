#!/usr/bin/env perl

use strict;
use IO::Select;
use IPC::Open2;
use IPC::Open3;

package BRM::Testnap;

use Carp;

our (@ISA);

BEGIN {
	require Exporter;
    @ISA = qw(Exporter);
    #@EXPORT = qw(BRM);
}

# module vars and their defaults
my $Indent = 2;
my ($tn0, $tn1);

# This is more about flist than testnap.
my %Type2Str = (
			 1 => "INT",
			 3 => "ENUM",
			 5 => "STR",
			 7 => "POID",
			 8 => "TSTAMP",
			 9 => "ARRAY",
			10 => "STRUCT",
			14 => "DECIMAL",
			15 => "TIME",
		);

my $Fields_ref;

sub convert_sdk_fields {
	my ($c, $sdk_hash) = @_;
	my %hash = ();
	
	# The key is the rec_id. Useless junk.
	# v is a hash with name, num, type.
	while (my($k,$v) = each (%$sdk_hash)) {
		$hash{$v->{PIN_FLD_FIELD_NAME}} = [
				$v->{PIN_FLD_FIELD_NUM},
				$v->{PIN_FLD_FIELD_TYPE},
				$Type2Str{$v->{PIN_FLD_FIELD_TYPE}}
			];
	}
	return \%hash;
}

sub set_dd_fields {
	my ($c) = shift;
	my $href = shift;
	$Fields_ref = $href;
}

sub new {
	my($c, $v, $n) = @_;

	my ($s) = {
		level => 0,
		indent => $Indent,
	};

	my $bless = bless($s, $c);
	
	$bless->connect;
	
	# Boot strap our own data dictionary.
	# $tn->get_sdk_field();
	#my $href = $tn->convert_sdk_fields($sdk_hash->{'PIN_FLD_FIELD'});
	#$tn->set_dd_fields($href);
	
	return $bless;
}

sub xop {
	my($c, $opcode, $opflags, $doc) = @_;
	my %h = \$c;
	printf $tn0 "r << +++ 1\n";
	printf $tn0 "%s\n", $doc;
	printf $tn0 "+++\n";
	printf $tn0 "xop %s %s 1\n", $opcode, $opflags;
	$c->testnap_read;
}

sub testnap_read {
	my($c) = @_;
	my %h = \$c;
	my ($elapsed) = 0.0;
	my @doc = [];
	printf "## Reading testnap enter\n";	
	while (my $line = <$tn1>){
		printf "## <testnap says>$line";
		chomp $line;
		push @doc, $line;
		if ($line =~ /^time: ([0-9\.]+)$/){
			$elapsed = $1;
			last;
		}
	}
	$h{last_op_elapsed} = $1;
	$h{total_op_elapsed} += $1;	
	printf "## Reading testnap exit\n";		
}

sub connect {
	my($c) = @_;
	my %h = \$c;
	if ($h{tn_pid} != 0 ){
		$c->quit();
	}

	use File::Spec;
	use Symbol qw(gensym);
	use IO::File;
	#$tn0 = IO::File->new_tmpfile;

	# I cannot grok the gensym. I get ref. But def of the thing. Hating Perl is unworthy love.
	# Perl is that land in the sand from which we became better. Great ideas can be butter.
	# I'd rather everything be part of the classes (instance?) href, but see above.
	# I try to limit these things b/c I cannot find the doc to describe scope.
	# Is Perl the new COBOL? Stop insulting COBOL.
	my($tn0, $tn1, $err) = (gensym, gensym, 0);

	my $pid = ::open3($tn0, $tn1, $err, 'testnap');
	
	$h {
		tn_pid=>$pid, tn0=>$wtr, tn1=>$rdr, tn2=>$err,
	};
	$h{last_op_elapsed} = 0.0;
	$h{total_op_elapsed} = 0.0;	

	printf $tn0 "p op_timing on\n";
	printf $tn0 "# Connected\n";
	printf $tn0 "id\n";
	$c->testnap_read();
	return;
}

sub connect2 {
	my($c) = @_;
	my %h = \$c;
	if ($h{tn_pid} != 0 ){
		$c->quit();
	}

	my($rdr, $wtr);
	$rdr = ">&";
	my $tn_pid = ::open2($rdr, \*Writer, "testnap")
	|| die "Bad open";
	printf Writer "echo connected\n";
	printf Writer "p logging on\n";
	printf Writer "p op_timing on\n";
	printf Writer "robj - DB /account 1\n\n";

	printf "## Reading testnap pipe output\n";
	while (my $line = <$rdr>){
		printf "## testnap:<$line>\n";
		last;
	}
	
	$h{tn_pid} = $tn_pid;

	printf "## Return %s\n", $?;
	printf "## Connected pid: ${tn_pid}\n";
	
}

sub quit {
	my($c) = @_;
	my %h = \$c;
	printf $h{tn0}, "q\n";
	waitpid($h{tn_pid}, 0);
	$h{
		tn_exit_status => $? >> 8,
		tn_pid => 0,
	};
}

sub doc2hash {
	my($c, $doc) = @_;
	my @ary = split(/\n/,$doc);
	my %main = ();
	my @stack;           # For any level, point to the current hashref.
	push @stack, \%main;

	# printf "## doc2hash enter\n";;
	my ($level, $fld_name, $fld_type, $fld_idx, $fld_value);
	foreach my $line (@ary) {

		next if $line =~ /^#/;
		if ($line =~ /^(\d+)\s+(.*?)\s+(\w+)\s+\[(\d+)\]\s*(.*$)/) {
			($level, $fld_name, $fld_type, $fld_idx, $fld_value) = (int($1), $2, $3, $4, $5);
		} else {
			croak "Bad initial line parse for \"$line\"\n";
			next;
		}

		if ($fld_type =~ /STR|POID/) {
			$fld_value =~ s/\"(.*?)\"/$1/;
			$stack[$level]->{$fld_name} = $fld_value;
		} elsif ($fld_type =~ /DECIMAL|INT|ENUM/) {
			$stack[$level]->{$fld_name} = $fld_value + 0;
		} elsif ($fld_type eq "TSTAMP") {
			if ($fld_value =~ /\((\d+?)\)/){
				$fld_value = int($1);
			} else {
				croak "Bad parse value \"$fld_value\"";
			}
			$stack[$level]->{$fld_name} = $fld_value;
		} elsif ($fld_type =~ /ARRAY|SUBSTRUCT/) {
			$stack[$level]->{$fld_name}->{$fld_idx} = {};
			$stack[$level+1] = $stack[$level]->{$fld_name}->{$fld_idx};
		} else {
			croak "Bad parse of \"$line\"";
		}
		# printf "## Parsed: %s %-30s %6s [%s] %s\n", $level, $fld_name, $fld_type, $fld_idx, $fld_value;
	}
	# printf "## doc2hash exit\n";
	return \%main;
}

# Convert a hash into a doc. The doc is passed to testnap.
# The challenge is that the keys don't 
# contain the data type that the doc needs to include.
#
# A boot strap is needed to first get the DD Objects. Use testnap.
# hash = xop("PCM_OP_SDK_GET_FLD_SPECS",0,"0 PIN_FLD_POID POID [0] 0.0.0.1 /dd/objects 0 0")
sub hash2doc {
	my ($c, $hash, $level, $idx) = @_;
	my @ary = ();
	$level ||= 0;
	$idx ||=0;
	#printf "## hash2doc enter level=${level} idx=$idx\n";
	#printf "## hash2doc convert %s", ::Dumper($hash);
	while (my($fld_name,$fld_value) = each (%$hash)) {
		my $fld_type = $Fields_ref->{$fld_name}->[2]
			|| die "Unknown field \"$fld_name\"";
		# printf "## hash2doc loop %-25s %10s [0] %s\n", $fld_name, $fld_type, $fld_value;

		# Should we branch on the DD field type or the Perl type?
		if (ref($fld_value) eq "HASH"){
			while (my($idx,$subhash) = each (%$fld_value)) {
				push @ary, [$level, $fld_name, $fld_type, $idx, ""];
				my @subdoc = $c->hash2doc($subhash, $level+1, $idx);
				foreach my $elem (@subdoc){
					push(@ary, @$elem);
				}
			}

		} else {
			push @ary, [$level, $fld_name, $fld_type, 0, $fld_value];
		}
	}
	
	# Convert each element of the array to a string.
	if ($level == 0){
		my @doc = ();
		foreach (@ary){
			# A fine example of how Perl sucks.
			my $line = sprintf "%s %-30s %10s [%s] %s", 
				$_->[0], $_->[1], $_->[2], $_->[3], $_->[4];
			push @doc, $line;
		}
		return join("\n", @doc);
	}
	#printf "## hash2doc exit\n";
	return \@ary;
}

1;
__END__
