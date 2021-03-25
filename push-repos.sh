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
push external

git add .
git commit -m 'updates'
git push
