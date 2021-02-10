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

git add .
git commit
git push
