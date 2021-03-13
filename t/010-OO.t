use strict;
use Test::More;

use Video::ProjectM::Render;

my $pcm = pack 's<*', map { int( rand() * ( 2 << 8 ) ) } 0 .. 48_100;
my $preset = '
[preset00]
fDecay=0.500000
nWaveMode=4
';

my $pmr = Video::ProjectM::Render->new( preset => $preset );

my $fh = $pmr->render($pcm);

is( ref $fh, 'GLOB', 'Render generated an output file' );

done_testing;
