#!/usr/bin/perl -I$HOME/perl5/lib/perl5

# TCNZ usage fetcher
# Chris Andreae <chris (at) andreae.gen.nz>

# Usage: edit $username, $password and $json_cache_file below
# Prints results as JSON to standard out, fetching new data if the cache file is older than $cache_max_age.
# If invoked with a command line argument, instead formats results as readable text.

use strict;
use LWP::UserAgent;
use HTTP::Cookies;

use HTML::TreeBuilder::XPath();

use JSON;

my $username = "";
my $password = "";
my $json_data_file = "";
my $cache_max_age = 5*60;

sub fetch(){
	my $ua = LWP::UserAgent->new;
	$ua->timeout(20);
	$ua->agent('Mozilla/5.0');
	$ua->cookie_jar({}); # empty temporary cookie jar
	push @{ $ua->requests_redirectable }, 'POST';
	$ua->show_progress(0);

	my $loginurl = "https://www.telstraclear.co.nz/amserver/UI/Login";
	my $loginform = {
		"goto" 		 => "https://www.telstraclear.co.nz/customer-zone/internet-usage-meters/usagemeter/index.cfm",
		"failUrl" 	 => "https://www.telstraclear.co.nz/selfservice-customerzone/login.jsf?goto=https://www.telstraclear.co.nz/customer-zone/internet-usage-meters/usagemeter/index.cfm",
		"IDToken0" 	 => "",
		"realm" 	 => "tclcustomers",
		"encoded" 	 => "false",
		"gx_charset" => "UTF-8",
		"service" 	 => "customer",
		"IDToken1" 	 => $username,
		"IDToken2" 	 => $password
	};

	my $response = $ua->post($loginurl, $loginform);

	if(!$response->is_success){
		print STDERR $response->status_line, "\n";
		exit(1);
	}

#parse main usage page for specific usage page
	my $tree = HTML::TreeBuilder::XPath->new_from_content($response->decoded_content);
	my $usageUrl = $tree->findvalue(q{//a[@class='mpUsage']/@href}); # Assume only one account - ignore complexity
	if(!defined($usageUrl)){
		print STDERR "Couldn't find usage URL on login page\n";
		exit(1);
	}
	$tree->delete;

# fetch specific usage data
# print "fetching Usage url: $usageUrl\n";
	$response = $ua->get($usageUrl);
	if(!$response->is_success){
		print STDERR $response->status_line, "\n";
		exit(1);
	}

#parse and print specific usage data

	my $tree = HTML::TreeBuilder::XPath->new_from_content($response->decoded_content);
	my $currentRow = $tree->findnodes(q{//tr[td[@class='usg_menuCurrent']]})->[0];

	my $usage = $currentRow->findvalue(q{td[5]/nobr/text()});
# Make numeric and normalize
	if($usage =~ m/MB/){
		$usage /= 1024.0;
	}
	else{
		$usage *= 1.0;
	}

	my $plan = $currentRow->findvalue(q{td[2]/text()});
	$plan =~ s/ *(.*)/$1/;
	$plan =~ m/([0-9]+)G/;
	my $quota = $1;

	my $period     = $currentRow->findvalue(q{td[4]/nobr/a/text()});
	$period =~ s/ -.*//;
	$period =~ s/([0-9]+) ([A-z]+)/$2 $1/; # Date::Calc parses MDY

	use Date::Calc;
	my @sd = Date::Calc::Parse_Date($period);
	my @ed = Date::Calc::Add_Delta_YMD(@sd, 0, 1, -1); # If we fetched the next page, we would be able to get an accurate end date rather than assuming +1 month.
	my $ed_text = "$ed[2] " . Date::Calc::Month_to_Text($ed[1]);
	my @now = Date::Calc::Today();
	my $period_days = Date::Calc::Delta_Days(@sd, @ed);
	my $elapsed_days = Date::Calc::Delta_Days(@sd, @now) + 1; # include both ends

	my $remaining_usage = $quota - $usage;
	my $remaining_days = $period_days - $elapsed_days;
	my $remaining_per_day = $remaining_usage / ($remaining_days || 1);

	my $daily_quota = $quota / $period_days;
	my $daily_usage = $usage / $elapsed_days;

	my $elapsed_quota = $daily_quota * $elapsed_days;

	my $usage_pc = $usage * 100 / $quota;
	my $elapsed_pc = $elapsed_days * 100 / $period_days;

#format
	my $usage_str = sprintf "%.2f GB / $quota GB", $usage;
	my $elapsed_str = "$elapsed_days / $period_days";

	my $rollover_str = "Rollover in $remaining_days days on $ed_text";

	my $remaining_str;
	if($remaining_usage > 0){
		$remaining_str = sprintf "%.3f GB remaining (%.3f GB per day)", $remaining_usage, $remaining_per_day;
	}
	else{
		$remaining_str = sprintf "Quota exceeded by %.3f GB", abs($remaining_usage);
	}

	my $daily_usage_str = sprintf "%.3f GB used each day", $daily_usage;


	my $export = { plan 	  		=> $plan,
				   usage_pc   		=> sprintf("%.1f", $usage_pc),
				   usage_text 		=> $usage_str,
				   time_pc 	  		=> sprintf("%.1f", $elapsed_pc),
				   time_text  		=> "$elapsed_str days",
				   remaining_text 	=> $remaining_str,
				   daily_usage_text => $daily_usage_str,
				   rollover_text 	=> $rollover_str,
	};
				   # summary 	  		=> "$remaining_str<br/>$daily_usage_str<br/>$rollover_str"};

	return $export;
}

sub save($$){
	my ($filename, $data) = @_;
	open OUT, ">$filename" || die "Couldn't save, can't open $filename";
	print OUT encode_json ($data);
	close OUT;
}

sub update_and_save($){
	my $filename = shift;
	my $data = fetch();
	save($filename, $data);
	return $data;
}

sub load($$){
	my ($filename, $maxage) = @_;
	my @stat = stat($filename);
	my $now = time();
	if(!@stat){
		# print STDERR "no file, updating\n";
		return update_and_save($filename);
	}
	elsif($stat[9] < ($now - $maxage)){
		# print STDERR "file old, updating\n";
		return update_and_save($filename);
	}

	open IN, "<$filename";
	my $body = join("", <IN>);
	close IN;
	my $data = eval { decode_json $body }; # "croak"s on error - presumably exits?
	if(!$data){
		# print STDERR "Could not decode data ($@), updating\n";
		return update_and_save($filename);
	}
	save($filename, $data);
	return $data;
}

if(scalar(@ARGV) >= 1){
	my $data = load($json_data_file, $cache_max_age);
	printf "%s\n", $data->{"plan"};
	printf "Data used: %s (%.1f%%)\n", $data->{"usage_text"}, $data->{"usage_pc"};
	printf "Days used: %s (%.1f%%)\n", $data->{"time_text"}, $data->{"elapsed_pc"};
	printf "%s\n", $data->{"rollover_text"};
	printf "%s\n", $data->{"remaining_text"};
	printf "%s\n", $data->{"daily_usage_text"};
}
else{
	my $data = load($json_data_file, $cache_max_age);
	my $json_data = encode_json $data;
	use CGI;
	my $q = CGI->new;
	print $q->header('application/json');
	print "$json_data\n";
}
exit(0);
