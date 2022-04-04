use strict;
use Test::More;

use Video::ProjectM::Render;

local $ENV{DISPLAY} = '';
my $pcm = pack 's<*', map { int( rand() * ( 2 << 8 ) ) } 0 .. 48_100;
my $preset = '
[preset00]
fDecay=0.500000
nWaveMode=4
';

use Time::HiRes qw/time/;
my $start = time;
my $pmr = Video::ProjectM::Render->new( preset => $preset);

my $fh = $pmr->render($pcm);
my $end = time;

note("Total time: " . ($end-$start));
is(ref $fh, 'GLOB', 'Render generated an output file');

done_testing;
