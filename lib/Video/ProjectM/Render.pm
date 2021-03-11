package Video::ProjectM::Render;

use v5.28;
use autodie;

use Moo;
use Try::Tiny;
use autodie;
use File::Temp qw/tempdir/;
use Scalar::Util qw/blessed/;
use List::Util qw/first max min/;
use Time::HiRes qw/time/;

use Types::Standard qw/Num Int Str HashRef InstanceOf/;

use namespace::clean;

has sample_rate => (
  is => 'ro',
  isa => Int,
  default => 44_100,
);

has fps => (
  is => 'ro',
  isa => Int,
  default => 120,
);

has frame_rate => (
  is => 'ro',
  isa => Int,
  default => 30,
);

has preset => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has vars => (
  is => 'rw',
  isa => HashRef,
  default => sub { {} },
  trigger => 1,
);

has xw => (
  is => 'ro',
  isa => Num,
  default => 640,
);

has yh => (
  is => 'ro',
  isa => Num,
  default => 360,
);

has tempdir => (
  is => 'ro',
  default => sub { tempdir },
);

has _vizual => (
  is => 'lazy',
  isa => InstanceOf['Video::ProjectM::Render::Viszul'],
  clearer => 1,
);

sub _trigger_vars
{
  my $self = shift;
  $self->clear__vizual;
}

sub _build__vizual
{
  my $self = shift;
  my $vars = $self->vars;
  my $tempdir = $self->tempdir;

  my $config = join("\n",
    "Mesh X  = 220",                   # Width of PerPixel Equation mesh
    "Mesh Y  = 125",                   # Height of PerPixel Equation mesh
    "FPS  = 35",
    "Fullscreen  = false",
    "Window Width  = 512",
    "Window Height = 512",
    "Easter Egg Parameter = 1",

    "Hard Cut Sensitivity = 10",
    "Aspect Correction = true",

    "Preset Path = $tempdir",
    "Title Font = Vera.ttf",
    "Menu Font = VeraMono.ttf",
  );

  open my $config_fh, '>', "$tempdir/config";
  $config_fh->print($config);
  open my $viz_fh, '>', "$tempdir/viz.milk";
  my $dotmilk = $self->preset;
  $dotmilk =~ s/{(\w+)}/$vars->{$1}/ge;
  $viz_fh->print($dotmilk);

  my $v = Video::ProjectM::Render::Viszul->new("$tempdir/config", "viz.milk", $self->xw, $self->yh, $self->frame_rate);

  return $v;
}

sub new_stream
{
  my $self = shift;
  my $pcm_data = shift;

  return Video::ProjectM::Render::Stream->new( VPR => $self, pcm => $pcm_data );
}

sub render
{
  my $self = shift;
  my $pcm_data = shift;
  my $vars = shift // {};
  my @new_options = @_;

  if (!blessed $self)
  {
    $self = $self->new(@new_options);
  }

  my $sample_rate = $self->sample_rate;

  open my $bgc_fh, '+>', undef;

  my $tempdir = tempdir;
  my $config = join("\n",
    "Mesh X  = 220",                   # Width of PerPixel Equation mesh
    "Mesh Y  = 125",                   # Height of PerPixel Equation mesh
    "FPS  = 35",
    "Fullscreen  = false",
    "Window Width  = 512",
    "Window Height = 512",
    "Easter Egg Parameter = 1",

    "Hard Cut Sensitivity = 10",
    "Aspect Correction = true",

    "Preset Path = $tempdir",
    "Title Font = Vera.ttf",
    "Menu Font = VeraMono.ttf",
  );

  {
    open my $config_fh, '>', "$tempdir/config";
    $config_fh->print($config);
    open my $viz_fh, '>', "$tempdir/viz.milk";
    my $dotmilk = $self->preset;
    $dotmilk =~ s/{(\w+)}/$vars->{$1}/ge;
    $viz_fh->print($dotmilk);
    mkdir "$tempdir/presets";
    mkdir "$tempdir/textures";
  }

  my $v = Video::ProjectM::Render::Viszul->new("$tempdir/config", "viz.milk", $self->xw, $self->yh, $self->frame_rate);

  my $frame = 0;
  my $iframe = 0;
  my $fps = $self->fps;
  my $afactor = $self->sample_rate / $self->frame_rate;
  my $vfactor = $self->frame_rate / $fps;
  my $duration = ( length($pcm_data) / 2) / $self->sample_rate;
  my $total_iframes = int($duration * $fps);

  $v->pcm(substr $pcm_data, int($afactor * $frame), int($afactor));

  while ( $iframe < $total_iframes )
  {
    my $s = $iframe / $fps;
    warn("$s\t$iframe\t$total_iframes\n");

    $v->render($s);
    if ( int($iframe * $vfactor) != int(($iframe-1) * $vfactor) )
    {
      $frame++;
      $v->save($bgc_fh);
      $v->pcm(substr $pcm_data, int($afactor * $frame), int($afactor));
    }
  }
  continue
  {
    $iframe++;
  }

  warn $frame;
  $bgc_fh->seek( 0, 0 );
  return $bgc_fh;
}

package Video::ProjectM::Render::Stream
{
  use Moo;
  use Types::Standard qw/Num Int Str InstanceOf/;

  use autodie;
  use File::Temp qw/tempdir/;

  use namespace::clean;

  has VPR => (
    is => 'ro',
    isa => InstanceOf['Video::ProjectM::Render'],
    required => 1,
  );

  has pcm => (
    is => 'ro',
    isa => Str,
    required => 1,
  );

  has _frame => (
    is => 'rwp',
    isa => Int,
    default => 0,
  );

  has _iframe => (
    is => 'rwp',
    isa => Int,
    default => 0,
  );

  has _max_frames => (
    is => 'lazy',
    isa => Int,
  );

  has _max_iframes => (
    is => 'lazy',
    isa => Int,
  );

  sub _build__max_frames
  {
    my $self = shift;
    my $pcm = $self->pcm;
    my $duration = ( length($pcm) / 2) / $self->VPR->sample_rate;
    my $frame_rate = $self->VPR->frame_rate;
    return int($duration * $frame_rate);
  }

  sub _build__max_iframes
  {
    my $self = shift;
    my $pcm = $self->pcm;
    my $duration = ( length($pcm) / 2) / $self->VPR->sample_rate;
    my $fps = $self->VPR->fps;
    return int($duration * $fps);
  }

  sub getline
  {
    my $self = shift;

    my $vpr = $self->VPR;
    my $v = $vpr->_vizual;

    my $pcm = $self->pcm;
    my $frame = $self->_frame;
    my $iframe = $self->_iframe;
    my $fps = $vpr->fps;
    my $afactor = $vpr->sample_rate / $vpr->frame_rate;
    my $vfactor = $vpr->frame_rate / $fps;
    my $total_iframes = $self->_max_iframes;

    return
      if $frame >= $self->_max_frames;

    $v->pcm(substr $pcm, int($afactor * $frame), int($afactor));

    while ( $iframe < $total_iframes )
    {
      my $s = $iframe / $fps;
      warn("$s\t$iframe\t$total_iframes\n");

      $v->render($s);
      if ( int($iframe * $vfactor) != int(($iframe-1) * $vfactor) )
      {
        #$frame++;
        #$result = $v->png_frame;
        #$v->pcm(substr $pcm, int($afactor * $frame), int($afactor));
        last;
      }
    }
    continue
    {
      $iframe++;
    }

    $self->_set__frame(++$frame);
    $self->_set__iframe(++$iframe);
    return $v->png_frame;
  }

  no warnings qw/prototype redefine/;
  sub close
  {
    my $self = shift;
    $self->_set__frame($self->_max_frames);
    return;
  }
};

use Config;

use Inline CPP => Config => ccflags => ''
    . ' -std=c++11 -mavx -mavx2 '
    . `pkg-config --cflags libprojectM osmesa libpng`
    , libs => `pkg-config --libs libprojectM osmesa libpng`
    , auto_include => "#undef seed",
    ;
use Inline CPP => <<'EOC';

#include "GL/osmesa.h"
#include "GL/gl.h"
#include <libprojectM/projectM.hpp>
#include <libprojectM/TimeKeeper.hpp>
#undef do_open
#undef do_close

extern "C" {
#include <png.h>
#include <stdio.h>
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "INLINE.h"
}

class TimeKeeperFixed : public TimeKeeper
{
  public:
    using TimeKeeper::TimeKeeper;
    double fixed_time;
    void UpdateTimers() override;
};

void TimeKeeperFixed::UpdateTimers()
{
  _currentTime = fixed_time;
  _presetFrameA++;
  _presetFrameB++;
}

class Viszul
{
  public:
    Viszul(const char* config_file, char* preset, int xw, int yh, int fps = 30);
    void pcm(SV* pcm_sv);
    void render(double time);
    SV* png_frame();
    void save(FILE* fh);
    std::string preset;
    ~Viszul();
  private:
   projectM* pm;
   TimeKeeperFixed* timekeeper;
   OSMesaContext ctx;
   GLubyte* buffer;
   int fps = 30;
   int xw = 400;
   int yh = 400;
};


Viszul::Viszul(const char* config_file, char* preset, int xw, int yh, int fps)
  : preset(preset), xw(xw), yh(yh), fps(fps)
{
  OSMesaContext ctx;
  GLubyte* buffer;

  /* specify Z, stencil, accum sizes */
  ctx = OSMesaCreateContextExt( OSMESA_RGB, 16, 0, 0, NULL );
  if ( !ctx )
  {
    croak("OSMesaCreateContext failed!\n");
  }

  /* Allocate the image buffer */
  int buffsz = xw * yh * 3 * sizeof(GLubyte);
  buffer = (GLubyte*) malloc( buffsz );
  if ( !buffer )
  {
    croak("Alloc image buffer failed!\n");
  }

  /* Bind the buffer to the context and make it current */
  if ( !OSMesaMakeCurrent( ctx, buffer, GL_UNSIGNED_BYTE, xw, yh ) )
  {
    croak("OSMesaMakeCurrent failed!\n");
  }

  this->ctx = ctx;
  this->buffer = buffer;
  pm = new projectM(config_file);
  if ( pm->timeKeeper != NULL )
  {
    delete pm->timeKeeper;
  }
  timekeeper = new TimeKeeperFixed(pm->_settings.presetDuration,pm->_settings.smoothPresetDuration, pm->_settings.hardcutDuration, pm->_settings.easterEgg);
  pm->timeKeeper = timekeeper;

  unsigned int preset_idx = pm->getPresetIndex(this->preset);
  pm->selectPreset(preset_idx);
  pm->setPresetLock(true);
  pm->projectM_resetGL( xw, yh );
}

void Viszul::pcm(SV* pcm_sv)
{
  STRLEN len;
  int16_t bitmax = ( 2 << ( 16 - 2 ) ) - 1;

  int16_t* pcm = (int16_t*) SvPV(pcm_sv, len);
  len = len >> 1;
  if ( len > 2048 )
  {
    croak("Unable to load more than 2048 pcm samples, got %d\n", len);
  }
  float pcm_float[len];
  for ( int i = 0; i < len; i++ )
  {
    pcm_float[i] = (pcm[i] / bitmax);
  }

  pm->pcm()->addPCMfloat(pcm_float, len );
}

void Viszul::render(double time)
{
  glClearColor( 0.0, 0.0, 0.0, 0.0 );
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

  timekeeper->fixed_time = time;
  pm->renderFrame();
}

SV* Viszul::png_frame()
{
  png_image img;
  memset(&img, 0, sizeof(img));

  img.version = PNG_IMAGE_VERSION;
  img.opaque = NULL;
  img.width = xw;
  img.height = yh;
  img.format = PNG_FORMAT_BGR;

  void *png_buffer = NULL;
  png_alloc_size_t png_len;

  int res = png_image_write_to_memory(
    &img, png_buffer, &png_len,
    0,        // convert_to_8_bit
    buffer,
    -PNG_IMAGE_ROW_STRIDE(img),       // row_stride
    NULL      // colormap
  );

  if ( img.warning_or_error & 3 )
  {
    croak("Could not find size of png: %s", img.message);
  }

  png_buffer = malloc(png_len);
  res = png_image_write_to_memory(
    &img, png_buffer, &png_len,
    0,        // convert_to_8_bit
    buffer,
    -PNG_IMAGE_ROW_STRIDE(img),       // row_stride
    NULL      // colormap
  );

  if ( img.warning_or_error & 3 )
  {
    croak("Could not find size of png: %s", img.message);
  }

  SV* result = newSVpv((char*)png_buffer, png_len);
  free(png_buffer);
  return result;
}

void Viszul::save(FILE* fh)
{
  png_image img;
  memset(&img, 0, sizeof(img));

  img.version = PNG_IMAGE_VERSION;
  img.opaque = NULL;
  img.width = xw;
  img.height = yh;
  img.format = PNG_FORMAT_BGR;

  int res = png_image_write_to_stdio(
    &img, fh,
    0,        // convert_to_8_bit
    buffer,
    -PNG_IMAGE_ROW_STRIDE(img),       // row_stride
    NULL      // colormap
  );

  if ( img.warning_or_error & 3 )
  {
    croak("Could not send png to fd: %s", img.message);
  }
}

Viszul::~Viszul()
{
  glFinish();
  OSMesaDestroyContext( ctx );
  free(buffer);
  delete(pm);
}

EOC

1;
