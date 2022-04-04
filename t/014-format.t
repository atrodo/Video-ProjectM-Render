use strict;
use autodie;
use Test::More;
use Try::Tiny;
use Time::HiRes qw/time/;

use Video::ProjectM::Render;

local $ENV{DISPLAY} = '';
my $pcm = pack 's<*', map { int( rand() * ( 2 << 8 ) ) } 0 .. 48_100;
my $preset = '
[preset00]
fDecay=0.500000
nWaveMode=4
';

my %opts = (
  preset => $preset,
  ffmpeg_cmd => $^X,
  ffmpeg_args => ['-Esay"output"', '--'],
);

foreach my $valid ( qw/png ogg mp4/ )
{
  my $pmr = try { Video::ProjectM::Render->new( %opts, format => $valid ) };
  isnt($pmr, undef, "$valid was a valid format");
}

foreach my $invalid ( qw/uri mp5 vorbis -/ )
{
  my $pmr = try { Video::ProjectM::Render->new( %opts, format => $invalid ) };
  is($pmr, undef, "$invalid was not a valid format");
}

my $start = time;
my $pmr = Video::ProjectM::Render->new( %opts, format => 'mp4' );

my $fh = $pmr->render($pcm);
my $end = time;

done_testing;
