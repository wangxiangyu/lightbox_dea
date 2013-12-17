#!/bin/bash

export PATH=/home/lightbox/warden/ruby193/bin:$PATH

function start()
{
  cd /home/lightbox/warden/dea/bin
  nohup ruby dea ../conf/dea.yml &>/dev/null &
}

function stop()
{
  ps -ef | grep 'ruby de[a]' | awk '{print $2}' | xargs kill
}

case ${1:-"other"} in
  start) start ;;
  stop) stop ;;
  *) echo "Usage: $0 start|stop|restart" ;;
esac
