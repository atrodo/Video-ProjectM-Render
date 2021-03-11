requires perl => '5.28';

requires 'Moo';
requires 'Types::Standard';
requires 'namespace::clean';
requires 'Try::Tiny';

requires 'Inline::C';
requires 'Inline::CPP';

recommends 'Plack::Builder';
on 'test' => sub {
  recommends 'HTTP::Request::Common';
};

recommends 'Plack::Builder';

# vim:set filetype=perl:
