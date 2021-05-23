#!/bin/bash

pull () {
  cd $1
  git pull
  cd ..
}

git pull
pull cynosure
pull refinement
pull external
pull tle
