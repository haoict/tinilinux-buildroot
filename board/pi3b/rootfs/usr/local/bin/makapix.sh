#!/bin/bash

if [ ! -d /usr/lib/python3.14/site-packages/PIL/ ] || [ ! -d /usr/lib/python3.14/site-packages/numpy/ ] || [ ! -d /usr/lib/python3.14/site-packages/requests/ ]; then
  pip install numpy Pillow requests
fi

exec /usr/local/bin/makapix.py "$@"
