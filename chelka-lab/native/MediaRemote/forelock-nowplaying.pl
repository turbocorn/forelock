#!/usr/bin/perl
use strict;
use warnings;
use DynaLoader;
my ($framework) = @ARGV;
die "Expected bundled framework" unless @ARGV == 1 && defined($framework) && $framework =~ m{^/.*\.framework$};
my $library = "$framework/MediaRemoteAdapter";
my $handle = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($handle, 'forelock_host_run') or die 'Missing Forelock host entry';
DynaLoader::dl_install_xsub('main::forelock_run', $symbol);
forelock_run();
