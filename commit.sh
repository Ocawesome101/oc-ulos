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
if [ "$#" > 0 ] ; then
  git commit "$@"
else
  git commit -m 'updates'
fi
