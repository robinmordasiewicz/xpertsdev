#!/bin/bash
#

get_greeting() {
  echo "I do not want this line used as part of the return value"
  echo "Hello there, $1!"
}

STRING_VAR=$(get_greeting "General Kenobi")
echo "$STRING_VAR"

