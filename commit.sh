#!/bin/bash

commit () {
  cd $1
  git add .
  git commit
  cd ..
}

commit cynosure
commit refinement

git add .
git commit -m 'updates'
