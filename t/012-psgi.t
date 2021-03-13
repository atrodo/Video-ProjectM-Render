use strict;
use autodie;
use Test::More;
use Plack::Test;
use HTTP::Request::Common;

use Video::ProjectM::Render;

my $pcm = pack 's<*', map { int( rand() * ( 2 << 8 ) ) } 0 .. 48_100;
my $preset = '
[preset00]
fDecay=0.500000
nWaveMode=4
';

test_psgi
    app    => Video::ProjectM::Render->as_psgi,
    client => sub
{
  my $cb = shift;
  my $r  = POST 'http://localhost/',
      Content_Type => 'form-data',
      Content      => [
    preset => [ undef, 'preset', Content => $preset ],
    pcm    => [ undef, 'pcm',    Content => $pcm ],
    frame_rate => 30,
    fps        => 120,
    xw         => 640,
    yh         => 360,
      ];

  my $res = $cb->($r);
  my $front = substr $res->content, 0, 10;
  like $front, qr/^.PNG/xms;
};

done_testing;
