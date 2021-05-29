#!/bin/bash
# setup the repos for dev work after a fresh clone when they aren't on a branch

switch () {
  cd $1
  git switch "$2"
  git checkout "$2"
  cd ..
}

switch cynosure dev
switch refinement master
switch external master
switch tle master
