#!/bin/bash
echo "Gracefully shutting down uploader"

screen -S dc-uploader -X stuff $'\003'