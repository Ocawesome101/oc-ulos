#!/bin/bash
# setup the repos for dev work after a fresh clone when they aren't on a branch

switch () {
  cd $1
  git switch master
  cd ..
}

switch cynosure
switch refinement
switch coreutils
