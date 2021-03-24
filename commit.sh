#!/bin/bash

commit () {
  cd $1
  git add .
  git commit
  cd ..
}

commit cynosure
commit refinement
commit coreutils

git add .
git commit -m 'updates'
