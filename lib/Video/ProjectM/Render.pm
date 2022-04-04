package Video::ProjectM::Render;

use v5.28;
use autodie;

use Moo;
use Try::Tiny;
use autodie;
use File::Temp qw/tempdir tempfile/;
use File::Basename qw/fileparse/;
use Scalar::Util qw/blessed/;
use List::Util qw/first max min/;
use Time::HiRes qw/time/;

use Types::Standard qw/Num Int Str ArrayRef HashRef InstanceOf HasMethods Enum/;

use namespace::clean;

our $VERSION = '0.001';

has sample_rate => (
  is      => 'ro',
  isa     => Int,
  default => 44_100,
);

has fps => (
  is      => 'ro',
  isa     => Int,
  default => 120,
);

has frame_rate => (
  is      => 'ro',
  isa     => Int,
  default => 30,
);

has preset => (
  is       => 'ro',
  isa      => Str,
  required => 1,
);

has vars => (
  is      => 'rw',
  isa     => HashRef,
  default => sub { {} },
  trigger => 1,
);

has xw => (
  is      => 'ro',
  isa     => Num,
  default => 640,
);

has yh => (
  is      => 'ro',
  isa     => Num,
  default => 360,
);

has remote_url => (
  is  => 'ro',
  isa => Str,
);

has ffmpeg_cmd => (
  is      => 'ro',
  isa     => Str,
  default => 'ffmpeg',
);

has ffmpeg_args => (
  is      => 'ro',
  isa     => ArrayRef [Str],
  default => sub { [] },
);

has format => (
  is      => 'ro',
  isa     => Enum [qw/png ogg mp4/],
  default => 'png',
);

has remote_ua => (
  is  => 'rw',
  isa => HasMethods['request'],
);

has tempdir => (
  is => 'ro',
  default => sub {tempdir},
);

has _vizual => (
  is      => 'lazy',
  isa     => InstanceOf ['Video::ProjectM::Render::Viszul'],
  clearer => 1,
);

sub _trigger_vars
{
  my $self = shift;
  $self->_clear_vizual;
}

sub _build__vizual
{
  my $self    = shift;
  my $vars    = $self->vars;
  my $tempdir = $self->tempdir;

  my $config = join(
    "\n",
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
  }

  my $v = Video::ProjectM::Render::Viszul->new(
    "$tempdir/config", "viz.milk",
    $self->xw, $self->yh, $self->frame_rate
  );

  return $v;
}

sub new_stream
{
  my $self           = shift;
  my $pcm_data       = shift;
  my $local_filename = shift;

  return Video::ProjectM::Render::Stream->new(
    VPR            => $self,
    pcm            => $pcm_data,
    local_filename => $local_filename // '',
  );
}

sub render
{
  my $self        = shift;
  my $pcm_data    = shift;
  my $vars        = shift // {};
  my @new_options = @_;

  if ( !blessed $self)
  {
    $self = $self->new( @new_options, vars => $vars );
  }

  if ( defined $self->remote_url )
  {
    my $ua = $self->remote_ua;
    if ( !defined $ua )
    {
      state $has_lwp = try { require LWP::UserAgent; 1; };
      if ( $has_lwp )
      {
        $self->remote_ua(LWP::UserAgent->new);
      }
    }

    if ( defined $ua )
    {
      require HTTP::Request::Common;
      my $r = HTTP::Request::Common::GET($self->remote_url);

      my $ua = $self->remote_ua;
      if ( $ua->can('timeout') )
      {
        $ua->timeout(3);
      }
      my $res = $ua->request( $r );

      if ( $res->is_success )
      {
        return $self->remote_render($pcm_data);
      }
    }
  }

  my $format = $self->format;

  if ( $format eq 'png' )
  {
    return $self->png_render($pcm_data);
  }

  my $ffmpeg_cmd = $self->ffmpeg_cmd;
  if ( !$ffmpeg_cmd || !-x $ffmpeg_cmd )
  {
    die "Cannot convert to $format without ffmpeg";
  }

  local $^F = 1024;
  my $png_fh = $self->png_render($pcm_data);

  return $self->render_png_fh( $png_fh, $pcm_data );
}

sub render_png_fh
{
  my $self     = shift;
  my $png_fh   = shift;
  my $pcm_data = shift;

  $png_fh->seek( 0, 0 );

  my $format = $self->format;
  if ( $format eq 'png' )
  {
    return $png_fh;
  }

  my $ffmpeg_cmd = $self->ffmpeg_cmd;
  if ( !$ffmpeg_cmd || !-x $ffmpeg_cmd )
  {
    die "Cannot convert to $format without ffmpeg";
  }

  local $^F = 1024;
  open my $pcm_fh, '+>', undef;
  $pcm_fh->print($pcm_data);
  $pcm_fh->seek( 0, 0 );

  my ( $fh, $filename ) = tempfile( "VRP_output_XXXXXXXX", delete => 0 );

  my @ffmpeg = (
    $ffmpeg_cmd,
    $self->ffmpeg_args->@*,
    '-y',
    '-nostdin',

    # Audio
    '-f'         => 's16le',
    '-ar'        => $self->sample_rate,
    '-ac'        => 1,
    '-blocksize' => '1024',
    '-i'         => "pipe:" . fileno $pcm_fh,

    # Video
    '-framerate', $self->frame_rate,
    '-f',         'image2pipe',
    '-i',         "pipe:" . fileno $png_fh,
  );

  if ( $format eq 'ogg' )
  {
    push @ffmpeg, (
      '-codec:v' => 'theora',
      '-q:v'     => '8',
      '-codec:a' => 'libvorbis',
      '-q:a'     => '8',
      '-f'       => 'ogg',
    );
  }

  if ( $format eq 'mp4' )
  {
    push @ffmpeg, (
      '-codec:v' => 'libx264',
      '-q:v'     => '8',
      '-codec:a' => 'aac',
      '-q:a'     => '8',
      '-f'       => 'mp4',
    );
  }
  push @ffmpeg, $filename;

  my $pid = fork // die "fork() failed: $!";
  if ( $pid == 0 )
  {
    exec @ffmpeg;
  }
  waitpid $pid, 0;

  $fh->seek( 0, 0 );
  return $fh;
}

sub png_render
{
  my $self     = shift;
  my $pcm_data = shift;

  open my $bgc_fh, '+>', undef;

  my $stream = $self->new_stream($pcm_data);
  while ( my $png = $stream->getline )
  {
    $bgc_fh->print($png);
  }

  $bgc_fh->seek( 0, 0 );
  return $bgc_fh;
}

sub remote_render
{
  my $self     = shift;
  my $pcm_data = shift // die "pcm_data is required for remote_render";

  die "remote_url is required for remote_render"
    if !defined $self->remote_url;
  die "remote_ua is required for remote_render"
    if !defined $self->remote_ua;

  require HTTP::Request::Common;

  open my $bgc_fh, '+>', undef;

  my $ua = $self->remote_ua;
  my $r = HTTP::Request::Common::POST($self->remote_url,
      Content_Type => 'form-data',
      Content      => [
    preset => [ undef, 'preset', Content => $self->preset ],
    pcm    => [ undef, 'pcm',    Content => $pcm_data ],
    frame_rate => $self->frame_rate,
    fps        => $self->fps,
    xw         => $self->xw,
    yh         => $self->yh,
      ]);

  my $start = time;
  my $res = $ua->request( $r, sub { $bgc_fh->print($_[0]) } );
  my $end = time;

  die "Could not fetch content"
    if !$res->is_success;

  warn Data::Dumper::Dumper(-s $bgc_fh, $end-$start, $res->headers);

  $bgc_fh->seek( 0, 0 );
  return $bgc_fh;
}

sub as_psgi
{
  require Plack::Request;
  require Plack::Response;
  my $app = sub
  {
    my $env = shift;
    my $req = Plack::Request->new($env);
    my $res = Plack::Response->new(500);

    if ( $req->method eq 'GET' )
    {
      return Plack::Response->new(200)->finalize;
    }

    try
    {
      my %vars     = $req->parameters->%*;
      my $pcm      = delete $vars{pcm};
      my $preset   = delete $vars{preset};
      my $give_uri = delete $vars{uri};

      if ( !$pcm && $req->upload('pcm') )
      {
        open my $fh, '<', $req->upload('pcm')->path;
        $pcm = do { local $/; <$fh> };
      }

      if ( !$preset && $req->upload('preset') )
      {
        open my $fh, '<', $req->upload('preset')->path;
        $preset = do { local $/; <$fh> };
      }

      my $pmr = Video::ProjectM::Render->new(
        preset     => $preset,
        frame_rate => delete $vars{frame_rate},
        fps        => delete $vars{fps},
        xw         => delete $vars{xw},
        yh         => delete $vars{yh},
        format     => delete $vars{format} // 'png',
        vars       => delete $vars{vars}   // \%vars,
      );
      warn Data::Dumper::Dumper( $pmr->vars );

      my $duration = ( length($pcm) / 2 ) / $pmr->sample_rate;
      warn "Will render $duration seconds\n";

      my $format = $pmr->format;
      my $ct
          = $format eq 'png' ? 'image/png'
          : $format eq 'ogg' ? 'video/ogg'
          : $format eq 'mp4' ? 'video/mp4'
          :                    die "Not a valid format: $format";

      my $output;

      if ($give_uri)
      {
        $ct = 'text/uri-list';

        my $filename = 'rendered_XXXXXXXX';
        if ( length $give_uri > 1 )
        {
          ( $filename, undef, undef ) = fileparse( $give_uri, qr/\.[^.]*/ );
          $filename = "$filename\_XXXXXXXX";
        }
        ( undef, $filename ) = tempfile($filename);
        $output = $pmr->new_stream( $pcm, "$filename.$format" );
      }
      elsif ( $format eq 'png' )
      {
        $output = $pmr->new_stream($pcm);
      }
      else
      {
        $output = $pmr->render;
      }

      $res = [
        200, [ 'Content-Type' => $ct ],
        $output
      ];

    }
    catch
    {
      warn $_;
      $res->body( 'Error: ' . $_ );
      $res = $res->finalize;
    };

    return $res;
  };
}

package Video::ProjectM::Render::Stream
{
  use Moo;
  use Types::Standard qw/Num Int Str FileHandle InstanceOf/;

  use autodie qw/mkdir/;
  use File::Temp qw/tempdir/;
  use File::Copy qw/copy/;
  use Time::HiRes qw/time/;
  use Fatal qw/copy/;

  use namespace::clean;

  has VPR => (
    is       => 'ro',
    isa      => InstanceOf ['Video::ProjectM::Render'],
    required => 1,
  );

  has pcm => (
    is       => 'ro',
    isa      => Str,
    required => 1,
  );

  has format => (
    is      => 'ro',
    isa     => Str,
    default => 'png',
  );

  has local_filename => (
    is      => 'ro',
    isa     => Str,
    default => '',
  );

  has local_dir => (
    is      => 'ro',
    isa     => Str,
    default => 'output/',
  );

  has _output_fh => (
    is  => 'rwp',
    isa => FileHandle,
  );

  has _getline_fn => (
    is  => 'lazy',
    isa => Str,
  );

  has _frame => (
    is      => 'rwp',
    isa     => Int,
    default => 0,
  );

  has _iframe => (
    is      => 'rwp',
    isa     => Int,
    default => 0,
  );

  has _max_frames => (
    is  => 'lazy',
    isa => Int,
  );

  has _max_iframes => (
    is  => 'lazy',
    isa => Int,
  );

  sub _build__max_frames
  {
    my $self       = shift;
    my $pcm        = $self->pcm;
    my $duration   = ( length($pcm) / 2 ) / $self->VPR->sample_rate;
    my $frame_rate = $self->VPR->frame_rate;
    return int( $duration * $frame_rate );
  }

  sub _build__max_iframes
  {
    my $self     = shift;
    my $pcm      = $self->pcm;
    my $duration = ( length($pcm) / 2 ) / $self->VPR->sample_rate;
    my $fps      = $self->VPR->fps;
    return int( $duration * $fps );
  }

  sub _build__getline_fn
  {
    my $self = shift;

    my $format = $self->format;

    if ( $format ne 'png' )
    {
      die "Cannot stream $format unless it is saved locally"
          if !$self->local_filename;

      my $ffmpeg_cmd = $self->VPR->ffmpeg_cmd;
      if ( !$ffmpeg_cmd || !-x $ffmpeg_cmd )
      {
        die "Cannot convert to $format without ffmpeg";
      }
    }

    if ( $self->local_filename )
    {
      local $^F = 1024;
      open my $png_fh, '+>', undef;
      $self->_set__output_fh($png_fh);
      return "url_frame";
    }

    return "png_frame";

    return "$format\_frame";
  }

  sub png_frame
  {
    my $self = shift;

    my $vpr = $self->VPR;
    my $v   = $vpr->_vizual;

    my $pcm           = $self->pcm;
    my $frame         = $self->_frame;
    my $iframe        = $self->_iframe;
    my $fps           = $vpr->fps;
    my $frame_rate    = $vpr->frame_rate;
    my $afactor       = ( $vpr->sample_rate / $vpr->frame_rate ) * 2;
    my $vfactor       = $vpr->frame_rate / $fps;
    my $total_iframes = $self->_max_iframes;

    return
        if $frame >= $self->_max_frames;

    if ( $frame % ( $frame_rate * 10 ) == 0 )
    {
      warn int( $frame / $frame_rate );
    }
    my $pcm_piece = substr $pcm, int( $afactor * $frame ), int($afactor);
    $v->pcm($pcm_piece);

    while ( $iframe < $total_iframes )
    {
      my $s = $iframe / $fps;

      $v->render($s);
      if ( int( $iframe * $vfactor ) != int( ( $iframe - 1 ) * $vfactor ) )
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

    $self->_set__frame( ++$frame );
    $self->_set__iframe( ++$iframe );
    return $v->png_frame;
  }

  sub url_frame
  {
    my $self = shift;

    my $result     = '';
    my $frame      = $self->_frame;
    my $frame_rate = $self->VPR->frame_rate;

    if ( $frame == 0 )
    {
      $result .= "#";
    }
    elsif ( $frame % $frame_rate == 0 )
    {
      $result .= "\n#";
    }

    my $png_frame = $self->png_frame;
    $result .= '.';

    if ( !defined $png_frame )
    {
      return;
    }

    if ( $self->_frame >= $self->_max_frames )
    {
      $result .= "\n" . $self->local_filename . "\n";

      if ( !-d $self->local_dir )
      {
        mkdir $self->local_dir;
      }
      my $fh = $self->VPR->render_png_fh( $self->_output_fh, $self->pcm );
      copy( $fh, $self->local_dir . '/' . $self->local_filename );
    }

    $self->_output_fh->print($png_frame);

    return $result;
  }

  sub getline
  {
    my $self = shift;
    my $fn   = $self->_getline_fn;

    return $self->$fn(@_);
  }

  has _start_time => ( is => 'ro', default => sub {time} );

  sub close
  {
    my $self = shift;
    $self->_set__frame( $self->_max_frames );

    my $n = time - $self->_start_time;
    warn "Took $n time\n";
    return;
  }
};

use Config;

use Inline CPP => Config => ccflags => ''
    . ' -std=c++11 -mavx -mavx2 '
    . `pkg-config --cflags libprojectM osmesa libpng x11 gl`,
    libs         => `pkg-config --libs libprojectM osmesa libpng x11 gl`,
    auto_include => "#undef seed",
    ;
use Inline CPP => <<'EOC';

#undef do_open
#undef do_close
#include "GL/osmesa.h"
#include "GL/gl.h"
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <libprojectM/projectM.hpp>
#include <libprojectM/event.h>

extern "C" {
#include <png.h>
#include <stdio.h>
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "INLINE.h"
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
   GLubyte* buffer;
   int fps = 30;
   int xw = 400;
   int yh = 400;

   OSMesaContext ctx = NULL;

   Display *d = NULL;
   Window w = 0;
   GLXContext glx_ctx = NULL;

   int initOSMesa();
   int initGLX();
};


Viszul::Viszul(const char* config_file, char* preset, int xw, int yh, int fps)
  : preset(preset), xw(xw), yh(yh), fps(fps)
{
  /* Allocate the image buffer */
  int buffsz = xw * yh * 4 * sizeof(GLubyte);
  buffer = (GLubyte*) malloc( buffsz );
  if ( !buffer )
  {
    croak("Alloc image buffer failed!\n");
  }

  initGLX() || initOSMesa();
  glEnable(GL_MULTISAMPLE);
  glEnable(GL_BLEND);
  glEnable(GL_LINE_SMOOTH);
  glEnable(GL_POINT_SMOOTH);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

  pm = new projectM(config_file);

  unsigned int preset_idx = pm->getPresetIndex(this->preset);

  pm->selectPreset(preset_idx);
  pm->setPresetLock(true);
  pm->projectM_resetGL( xw, yh );
  pm->key_handler(PROJECTM_KEYDOWN, PROJECTM_K_F5, PROJECTM_KMOD_NONE);
  pm->key_handler(PROJECTM_KEYUP, PROJECTM_K_F5, PROJECTM_KMOD_NONE);
  pm->key_handler(PROJECTM_KEYDOWN, PROJECTM_K_F4, PROJECTM_KMOD_NONE);
  pm->key_handler(PROJECTM_KEYUP, PROJECTM_K_F4, PROJECTM_KMOD_NONE);
}

void Viszul::pcm(SV* pcm_sv)
{
  STRLEN len;
  int16_t bitmax = ( 2 << ( 16 - 2 ) ) - 1;

  int16_t* pcm = (int16_t*) SvPV(pcm_sv, len);
  len = len >> 1;
  if ( len > 2048 )
  {
    croak("Unable to load more than 2048 pcm samples, got %d\n", (int)len);
  }
  float pcm_float[len];
  float total = 0;
  float min = 0;
  float max = 0;
  for ( int i = 0; i < len; i++ )
  {
    pcm_float[i] = ((float)pcm[i] / bitmax);
    min = pcm_float[i] < min ? pcm_float[i] : min;
    max = pcm_float[i] > max ? pcm_float[i] : max;
    total += pcm_float[i];
  }
  if ( max < 0.002 )
  {
    memset(&pcm_float, 0, len * sizeof(float));
  }

  pm->pcm()->addPCMfloat(pcm_float, len );
}

int Viszul::initOSMesa()
{
  OSMesaContext ctx;

  /* specify Z, stencil, accum sizes */
  ctx = OSMesaCreateContextExt( OSMESA_RGB, 24, 8, 16, NULL );
  if ( !ctx )
  {
    croak("OSMesaCreateContext failed!\n");
  }

  /* Bind the buffer to the context and make it current */
  if ( !OSMesaMakeCurrent( ctx, buffer, GL_UNSIGNED_BYTE, xw, yh ) )
  {
    croak("OSMesaMakeCurrent failed!\n");
  }

  this->ctx = ctx;
  return 1;
}

typedef GLXContext (*glXCreateContextAttribsARBProc) (Display*, GLXFBConfig, GLXContext, Bool, const int*);
int Viszul::initGLX()
{
  d = XOpenDisplay(NULL);

  if (!d)
  {
    return 0;
  }

  w = XCreateSimpleWindow(d, DefaultRootWindow(d),
                            10, 10,
                            xw, yh,
                            0, 0,
                            0
                           );

  static int visual_attribs[] = {
        GLX_X_VISUAL_TYPE,  GLX_TRUE_COLOR,
        GLX_DOUBLEBUFFER,   True,
        None
    };

  int scrnum = DefaultScreen( d );
  Window root = RootWindow( d, scrnum );

  int num_fbc = 0;
  GLXFBConfig *fbc = glXChooseFBConfig(d, scrnum, visual_attribs, &num_fbc);
  if (!fbc)
  {
      return 0;
  }

  for (int i = 0; i < num_fbc; i++)
  {
    int id, r, g, b, depth, db, sb, spls;
    glXGetFBConfigAttrib(d, fbc[i], GLX_FBCONFIG_ID, &id);
    glXGetFBConfigAttrib(d, fbc[i], GLX_RED_SIZE, &r);
    glXGetFBConfigAttrib(d, fbc[i], GLX_GREEN_SIZE, &g);
    glXGetFBConfigAttrib(d, fbc[i], GLX_BLUE_SIZE, &b);
    glXGetFBConfigAttrib(d, fbc[i], GLX_BUFFER_SIZE, &depth);
    glXGetFBConfigAttrib(d, fbc[i], GLX_DOUBLEBUFFER, &db);
    glXGetFBConfigAttrib(d, fbc[i], GLX_SAMPLE_BUFFERS, &sb);
    glXGetFBConfigAttrib(d, fbc[i], GLX_SAMPLES, &spls);
    warn("%d\t%d.%d.%d\tDepth: %d\tDB: %d\t%d/%d\n", id, r, g, b, depth, db, sb, spls);
  }

  glXCreateContextAttribsARBProc glXCreateContextAttribsARB = (glXCreateContextAttribsARBProc) glXGetProcAddress((const GLubyte*)"glXCreateContextAttribsARB");

  if (!glXCreateContextAttribsARB)
  {
    return 0;
  }

  static int context_attribs[] = { None };
  glx_ctx = glXCreateNewContext( d, fbc[0], GLX_RGBA_TYPE, 0, True );
  XFree( fbc );

  if (!glx_ctx)
  {
    return 0;
  }

  warn("%s GLX rendering context obtained\n", glXIsDirect( d, glx_ctx ) ? "Direct" : "Indirect");

  XMapWindow( d, w );
  glXMakeCurrent(d, w, glx_ctx);

  if ( glGetError() != GL_NO_ERROR )
  {
    while ( glGetError() != GL_NO_ERROR ) {};
    warn("Got error, not using glx\n");
    XUnmapWindow(d, w);
    glXDestroyContext( d, glx_ctx );
    glx_ctx = NULL;
    w = 0;
    return 0;
  }

  if ( glXGetCurrentContext() == NULL )
  {
    warn("Could not make ctx current, not using glx\n");
    XUnmapWindow(d, w);
    glx_ctx = NULL;
    w = 0;
    return 0;
  }

  glClearColor( 0.0, 0.0, 0.0, 0.0 );
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  glXSwapBuffers( d, w );

  printf("GL_RENDERER = %s\n", (char*)glGetString(GL_RENDERER));
  printf("GL_VERSION = %s\n", (char*)glGetString(GL_VERSION));
  printf("GL_VENDOR = %s\n", (char*)glGetString(GL_VENDOR));
  printf("GL_SHADING_LANGUAGE_VERSION = %s\n", (char*)glGetString(GL_SHADING_LANGUAGE_VERSION));

  return 1;
}

void Viszul::render(double time)
{
  glClearColor( 0.0, 0.0, 0.0, 0.0 );
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

  pm->setNextFrameTime(time);
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
  img.format = PNG_FORMAT_RGB;

  void *png_buffer = NULL;
  png_alloc_size_t png_len = xw * yh * 8;
  int res;

  if ( glx_ctx != NULL )
  {
    glXSwapBuffers( d, w );
  }

  GLubyte* tmp_buffer = (GLubyte*) malloc(png_len);
  glReadBuffer(GL_FRONT);
  glReadPixels(0, 0, xw, yh,  GL_RGB,  GL_UNSIGNED_BYTE, tmp_buffer);
  glReadBuffer(GL_BACK);

  png_buffer = malloc(png_len);
  res = png_image_write_to_memory(
    &img, png_buffer, &png_len,
    0,        // convert_to_8_bit
    tmp_buffer,
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
  if ( ctx != NULL )
  {
    OSMesaDestroyContext( ctx );
  }
  if ( glx_ctx != NULL )
  {
    glXDestroyContext( d, glx_ctx );
  }
  if ( w != NULL )
  {
    XUnmapWindow(d, w);
  }
  if ( d != NULL )
  {
    XCloseDisplay( d );
  }
  free(buffer);
  delete(pm);
}

EOC

1;

__END__

=encoding utf-8

=head1 NAME

Video::ProjectM::Render - Blah blah blah

=head1 SYNOPSIS

use Video::ProjectM::Render;

=head1 DESCRIPTION

Video::ProjectM::Render is

=head1 AUTHOR

Jon Gentle E<lt>cpan@atrodo.orgE<gt>

=head1 COPYRIGHT

Copyright 2021- Jon Gentle

=head1 LICENSE

This is free software. You may redistribute copies of it under the terms of the Artistic License 2 as published by The Perl Foundation.

=head1 SEE ALSO

=cut
