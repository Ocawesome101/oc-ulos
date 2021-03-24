#!/bin/bash

push () {
  cd $1
  git add .
  git commit
  git push
  cd ..
}

push cynosure
push refinement
push coreutils

git add .
git commit
git push
