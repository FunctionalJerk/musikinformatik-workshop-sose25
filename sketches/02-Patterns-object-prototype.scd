
// drums folder with both loops and single hits
~folder = "/my/folder/with/drums"

(
// start over
Buffer.freeAll;
FluidDataSet.freeAll;
FluidKDTree.freeAll;
)

s.options.numBuffers = 4096;
s.reboot;

~loader = FluidLoadFolder(~folder).play(s,{"done loading folder".postln});
~winSize = 512;

// sum to mono (if not mono)
(
if(~loader.buffer.numChannels > 1){
	~src = Buffer(s);
	~loader.buffer.numChannels.do{
		arg chan_i;
		FluidBufCompose.processBlocking(s,
			~loader.buffer,
			startChan: chan_i,
			numChans: 1,
			gain: ~loader.buffer.numChannels.reciprocal,
			destination: ~src,
			destGain: 1,
			action:{"copied channel: %".format(chan_i).postln}
		);
	};
}{
	"loader buffer is already mono".postln;
	~src = ~loader.buffer;
};
)

// stripping silence:
// decide for yourself if this makes any sense for you.
// otherwise skip this part
// I would expect the number of slices found here
// to be LESS than the indices found through onset detection
(
fork{
	var indices = Buffer(s);
	var temp = Buffer(s);

	FluidBufAmpGate.processBlocking(
		server: s,
		source: ~src,
		indices: indices,
		onThreshold: -55,
		offThreshold: -60,
		minSliceLength: ~src.sampleRate * 0.1,
		rampUp: 100,
		rampDown: 100,
		// highPassFreq: 20,
	);
	s.sync;

	indices.loadToFloatArray(action:{ |fa|
		var curr = 0;
		fa.clump(2).do({ |arr,index|
			var start = arr[0];
			var num = arr[1] - start;
			FluidBufCompose.processBlocking(
				server: s,
				source: ~src,
				startFrame: start,
				numFrames: num,
				destination:temp,
				destStartFrame:curr
			);
			curr = curr + num;
			s.sync;
			"Slice no: % / %\n".postf(index+1,(fa.size / 2).asInteger);
		});
		indices.free;
	});
	"Done stripping % frames!\n".postf(~src.numFrames - temp.numFrames);
	~src.free;
	~src = temp;
}
)


(
~indices = Buffer(s);
FluidBufOnsetSlice.processBlocking(s,
	source: ~src,
	metric: 9,
	threshold: 0.21,
	minSliceLength: 2,
	windowSize: ~winSize,
	indices: ~indices,
	action:{
		"found % slice points\n".postf(~indices.numFrames);
		"average duration per slice: %\n".postf(~src.duration / (~indices.numFrames+1));
	}
);
)

(
~dataset = FluidDataSet(s);

~indices.loadToFloatArray( action: { |fa|
	fa.doAdjacentPairs{ |start, end, i|
		var featuresBuffer = Buffer(s);
		var statBuffer = Buffer(s);
		var flatBuffer = Buffer(s);

		FluidBufSpectralShape.processBlocking(s,
			source: ~src,
			startFrame: start,
			numFrames: end - start,
			// numFrames: 48000 * 0.2,
			features: featuresBuffer,
			windowSize: ~winSize,
		);
		// Convert MFCCs to a single feature vector (mean across frames)
		FluidBufStats.processBlocking(
			server: s,
			source: featuresBuffer,
			select: [\mean],
			stats: statBuffer,
		);
		FluidBufFlatten.processBlocking(
			server: s,
			source: statBuffer,
			destination: flatBuffer,
		);

		// add this point to the dataset
		~dataset.addPoint(i,flatBuffer);

		// free the buffers
		featuresBuffer.free;
		statBuffer.free;
		flatBuffer.free;

		"% / %\n".postf(i+1, fa.size);
		// if you get warnings in the output,
		// you can decrease this number to sync more often
		if(i%5==0) {s.sync}
	};
	s.sync;
	~dataset.print;
});
)

// object prototyping
(
~makePatternObject = {|server,src,path,dataset,indices,id|
	(
		server: server ? s,
		src: src,
		path: path,
		dataset: dataset,
		indices: indices,
		id: id ? 0,

		kdtree: nil,
		umapped: nil,
		normed: nil,
		dict: nil,
		numDimensions: 2,
		numDatapoints: nil,
		pointBuf: nil,
		envBuf: Buffer.loadCollection(server, Env.perc.discretize),
		name: { PathName.new(path).folderName },
		eventName: {|self| (self.name ++ "_" ++ self.id.asString).asSymbol },
		synthName: {|self| ("play_" ++ self.name ++ "_" ++ self.id.asString).asSymbol },
		makeSynth: {|self|
			SynthDef(self.synthName, {|index, envBuf, rate=1, repeats=1, amp=1, pos=0, out|

				var buf = self.src;
				var startsamp = Index.kr(self.indices,index);
				var stopsamp = Index.kr(self.indices,index+1);
				var phs = Phasor.ar(0,BufRateScale.ir(buf) * rate,startsamp,stopsamp);
				var sig = BufRd.ar(1, buf, phs);

				var dursecs = (stopsamp - startsamp) / BufSampleRate.ir(buf) / rate * repeats;
				var env = BufRd.ar(1, envBuf, Line.ar(0, BufFrames.ir(envBuf) - 1, dursecs, doneAction: 2), loop:0);

				OffsetOut.ar(out, Pan2.ar(sig * env * amp, pos));
			}).add;
		},
		makeEventType: {|self|
			Event.addEventType(self.eventName, {|server|
				var point, vec, vecLength;
				var window;
				var center = self.dict.at("data").at(~index.asString);

				var repeats = ~repeats ? 1;
				var numNeighbors = ~k ? 1;
				var phi = ~phi ? 1;
				var out = ~out ? 0;
				var amp = ~amp ? 0.5;
				var dist = ~dist ? 0;
				var rate = ~rate ? 1;

				vec = [cos(phi), sin(phi)];
				vecLength = vec.squared.sum.sqrt;
				vec = vec / vecLength * dist.abs;
				point = center + vec % 1.0;

				Buffer.loadCollection(self.server, point, action: {|buf|

					self.kdtree.kNearest(buf, numNeighbors, { |nearest|
						nearest = nearest.bubble.flat;
						// nearest.postln;
						nearest.do{|n,i|
							defer{
								~fp.notNil.if(
									~fp.highlight_(n.asSymbol);
								)
							};
							Synth.grain(self.synthName, [
								\index, n.asInteger,
								\envBuf, self.envBuf,
								\repeats, repeats,
								\amp, amp,
								// \pos, phi + (i*0.5),
								\rate, rate,
								\out, out,
							], self.server);
						}
					});
					buf.free;
				})
			})
		},
		plot: {|self|
			var previous = nil;
			~fp = FluidPlotter(
				dict: self.dict,
				// standalone:false,
				mouseMoveAction: {|view,x,y|
					var point = self.pointBuf;

					point.setn(0,[x,y]);

					self.kdtree.kNearest(point,1,action: {|nearest|

						if(nearest != previous){
							nearest.postln; // look for suitable starting / center points
							view.highlight_(nearest);
							Synth(self.synthName, [
								\index, nearest.asInteger,
								\envBuf, self.envBuf,
								\amp, 0.5,
							], self.server);
							// nearest.postcs;
							previous = nearest;
						}
					})
				}
			)
		},
		makePlot: {|self|
			defer{
				self.plot;
			}
		},
		init: {|self|
			"initializing …".postln;

			self.kdtree = FluidKDTree(self.server);
			self.umapped = FluidDataSet(self.server);
			self.normed = FluidDataSet(self.server);

			FluidUMAP(
				server:self.server,
				numDimensions:self.numDimensions,
				numNeighbours:8,
				minDist:4,
				iterations:400,
				learnRate:0.5
			).fitTransform(self.dataset,self.umapped,action:{
				FluidNormalize(self.server).fitTransform(
					sourceDataSet:self.umapped,
					destDataSet:self.normed,
					action:{
						self.normed.dump({|dict| self.dict = dict });
						self.kdtree.fit(self.normed,action:{

							self.makeSynth;
							self.makeEventType;
							self.pointBuf = Buffer.alloc(self.server, self.numDimensions);
							"… done!".postln;
						})
					}
				)
			})
		},
	)
}
)

// create and initialize event type:
// IDs help us adress the same dataset in different patterns.

~drumSet = ~makePatternObject.(s, ~src, ~folder, ~dataset, ~indices);
~drumSet.init;

// plot and check if it makes any sense
// this is the space we'll navigate with vectors soon
~drumSet.makePlot;

//test event type
(type: ~drumSet.eventName, index: 80, amp: 0.5, phi: 2pi.rand2, dist: 0.1).play
(type: ~drumSet.eventName, index: 80, amp: 0.5, phi: 2pi.rand2, dist: 0.1).play

// change envelope
~drumSet.envBuf = Buffer.loadCollection(s, Env.perc(0.001,curve:0).discretize);
~drumSet.envBuf = Buffer.loadCollection(s, Env.sine.discretize);

(
// circular motion with exponentially growing distance
Pdef(\drm, Pbind(
	\type, 'drums_0',
	\index, 363,
	// \phi, Pwhite(-2pi, 2pi, inf),
	\phi, Pseg([-2pi, 2pi], 4, repeats: inf),
	\dist, Pseg([0.01,0.2], 16, curves: 'exp', repeats: inf),
	\repeats, Pstep([1,2,4,6], 1, inf),
	\dur, 0.5,
	\stretch, 1 / Pkey(\repeats),
	\rate, Pkey(\repeats) * 0.5,
	\amp, 0.5,
)).play(quant:1)
)

(
// random motion sinusoidal distance
Pdef(\drm, Pbind(
	\type, \drums_0,
	\index, 485,
	\phi, Pwhite(-2pi, 2pi, inf),
	\dist, Pseg([0.0,0.4,0.0], 4, 'sin', inf),
	\dur, 0.125,
	\amp, 0.5,
)).play(quant:1)
)

(
// Backbeat variation
Pdef(\drm1, Pbind(
	\type, \drums_1,
	\index, Pstep([485,245], 0.5, inf),
	\phi, Pwhite(-2pi, 2pi, inf),
	\dist, Pwhite(0.0,0.05,inf),
	\dur, Pseq([0.25,0.25,0.5], inf),
	\amp, 0.5,
)).play(quant:1);
)
(
// groove variation
Pdef(\grv, Pbind(
	\type, \drums_0,
	\index, 629,
	\phi, Pseg([-2pi, 2pi], 4, repeats: inf),
	\dist, Pwhite(0.0,0.05,inf),
	\dur, 1 / 6,
	\amp, 0.5,
)).play(quant:1)
)




