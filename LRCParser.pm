package Plugins::MusicArtistInfo::LRCParser;

use strict;

use File::Slurp;

use Slim::Utils::Log;

# parse lyrics file according to https://en.wikipedia.org/wiki/LRC_(file_format)

my $log = logger('plugin.musicartistinfo');

sub parseLRC {
	my ($class, $path) = @_;

	return unless -r $path;

	if (-s $path > 100_000) {
		$log->warn('File is >100kB - likely not lyrics. Skipping ' . $path);
		return;
	}

	# only show empty lines if they come in line, but not at the top of the file
	my $textFound = 0;
	my $content = join('', grep {
		$textFound ||= /\w/;
		$textFound;
	} map {
		# remove some metadata
		s/\[(?:ar|al|ti|au|length|by|offset|re|ve):.*?\]//g;
		# remove timestamps
		s/^\[\d+.*?\]//g;
		# Enhanced LRC format is an extension of Simple LRC Format developed by the designer of A2 Media Player
		s/<\d+:\d+\.\d+>//g;
		$_;
	} File::Slurp::read_file($path));

	return $content;
}


1;