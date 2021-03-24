#!/bin/bash

commit () {
  cd $1
  git add .
  git commit
  cd ..
}

commit cynosure
commit refinement
commit external

git add .
git commit -m 'updates'
