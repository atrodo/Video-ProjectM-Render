use strict;
use autodie;
use Test::More;

use Video::ProjectM::Render;

local $ENV{DISPLAY} = '';
my $pcm = pack 's<*', map { int( rand() * ( 2 << 8 ) ) } 0 .. 48_100;
my $preset = '
[preset00]
fDecay=0.500000
nWaveMode=4
';

my $pmr = Video::ProjectM::Render->new( preset => $preset );

my $fh_like = $pmr->new_stream($pcm);

open my $bgc_fh, '+>', undef;
my $frames = 0;
while ( my $png = $fh_like->getline )
{
  $bgc_fh->print($png);
  $frames++;
}

is( $frames, 32, 'Created all the expected frames' );

done_testing;
