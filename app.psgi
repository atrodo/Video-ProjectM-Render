#!/usr/bin/env plackup

use v5.28;
use strict;
use Video::ProjectM::Render;

Video::ProjectM::Render->as_psgi;
