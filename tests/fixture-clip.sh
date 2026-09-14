#!/bin/bash
# The synthetic clip both the bats suite and the event-stream fixture are built from. Sourced, not
# run: two copies of this had already diverged in their arguments.
#
# HOW IT IS TAGGED, which is the part that matters. Passing -color_primaries/-color_trc/-colorspace
# to prores_ks does NOT produce a correctly tagged file: it writes "bt709,unknown,unknown". That is
# the very bug the pipeline's retag pass exists for, and the first version of the suite tripped over
# it — a fixture named "correctly tagged" that wasn't, failing a test of a function that was working
# fine. So the clip is built the way the pipeline builds real output: encode first, then apply tags
# in a separate `-c copy` remux.
make_tagged_clip() {  # make_tagged_clip <w> <h> <primaries> <trc> <matrix> <out>
	ffmpeg -y -v error -f lavfi -i "color=c=gray:s=${1}x${2}:d=0.1:r=24" \
		-frames:v 1 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$6.raw.mov"
	ffmpeg -y -v error -i "$6.raw.mov" -map 0:v:0 -c copy \
		-color_primaries "$3" -color_trc "$4" -colorspace "$5" "$6"
	rm -f "$6.raw.mov"
}
