using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
namespace PortableVideo {
    public sealed class MediaGap { public double Previous, Next; }
    public sealed class MediaRun {
        public int Stream, Width, Height;
        public long Frames;
        public double Start, Last, End;
        public string PixelFormat, Reason;
        public List<double> Times = new List<double>();
        public List<MediaGap> Gaps = new List<MediaGap>();
    }
    public static class MediaPlanner {
        private sealed class Sample {
            public int Stream, Width, Height;
            public double Time;
            public bool Key;
            public string PixelFormat;
        }
        public static List<MediaRun> Read(string path, double interval, double splitSeconds, List<long> sourceTicks) {
            return Plan(path, interval, splitSeconds, sourceTicks, false);
        }
        public static List<MediaRun> ReadPackets(string path, double interval, double splitSeconds, List<long> sourceTicks) {
            return Plan(path, interval, splitSeconds, sourceTicks, true);
        }
        private static List<MediaRun> Plan(string path, double interval, double splitSeconds, List<long> sourceTicks, bool packets) {
            if (splitSeconds<0 || double.IsNaN(splitSeconds) || double.IsInfinity(splitSeconds)) throw new ArgumentException("Invalid split duration.");
            List<Sample> samples = new List<Sample>();
            foreach (string line in File.ReadLines(path)) {
                Dictionary<string,string> f=new Dictionary<string,string>();
                foreach(string part in line.Split('|')) { int pos=part.IndexOf('='); if(pos>0) f[part.Substring(0,pos)]=part.Substring(pos+1); }
                if(!f.ContainsKey("stream_index")) continue;
                if(!packets && !f.ContainsKey("width")) continue;
                string timestamp=packets?"pts_time":"best_effort_timestamp_time";
                double time;
                if(!f.ContainsKey(timestamp) || !double.TryParse(f[timestamp],NumberStyles.Float,CultureInfo.InvariantCulture,out time))
                    throw new IOException("A video frame has no presentation timestamp.");
                Sample s=new Sample { Stream=int.Parse(f["stream_index"]),Time=time,Key=packets?f["flags"].Contains("K"):f["key_frame"]=="1" };
                if(!packets){s.Width=int.Parse(f["width"]);s.Height=int.Parse(f["height"]);s.PixelFormat=f["pix_fmt"];}
                samples.Add(s);
            }
            if(samples.Count==0) throw new IOException("No video packets/frames.");
            if(packets) samples.Sort(delegate(Sample a,Sample b){return a.Time.CompareTo(b.Time);});
            List<MediaRun> runs=new List<MediaRun>(); MediaRun run=null;
            double first=samples[0].Time, next=first+splitSeconds, previous=first;
            double gap=Math.Max(interval*3,interval+0.1);
            for(int i=0;i<samples.Count;i++) {
                Sample s=samples[i];
                if(s.Stream!=samples[0].Stream) throw new IOException("Multiple active video tracks cannot be combined into one lossless MP4. Preserve MKV for review; no automatic splitting.");
                if(i>0 && s.Time<=previous) throw new IOException("Non-increasing presentation timestamps.");
                if(sourceTicks!=null && (i>=sourceTicks.Count || Math.Abs((s.Time-first)-(sourceTicks[i]-sourceTicks[0])/10000000.0)>0.002))
                    throw new IOException("Source/export timestamp mismatch at frame "+i);
                if(run!=null && !packets && (s.Width!=run.Width || s.Height!=run.Height || s.PixelFormat!=run.PixelFormat))
                    throw new IOException("Image format changes inside the recording. Preserve MKV for review; no automatic splitting.");
                bool cut=run==null || (splitSeconds>0 && s.Time>=next && s.Key);
                if(cut){
                    if(!s.Key) throw new IOException("The recording does not start at a keyframe.");
                    if(run!=null) run.End=s.Time;
                    run=new MediaRun {Stream=s.Stream,Width=s.Width,Height=s.Height,PixelFormat=s.PixelFormat,Start=s.Time,Reason=runs.Count==0?"start":"duration"};
                    runs.Add(run);
                    if(splitSeconds>0) next=first+(Math.Floor((s.Time-first)/splitSeconds)+1)*splitSeconds;
                }
                if(i>0 && s.Time-previous>gap) run.Gaps.Add(new MediaGap {Previous=previous,Next=s.Time});
                run.Frames++;run.Last=s.Time;run.End=s.Time+interval;run.Times.Add(s.Time);previous=s.Time;
            }
            // Avoid an extra file for the approximately one-second boundary GOP included by some exports.
            if(runs.Count>1 && splitSeconds>0){
                MediaRun tail=runs[runs.Count-1];
                if(tail.End-tail.Start<=Math.Min(2.0,splitSeconds*0.01)){
                    MediaRun before=runs[runs.Count-2];before.Last=tail.Last;before.End=tail.End;before.Frames+=tail.Frames;
                    before.Times.AddRange(tail.Times);before.Gaps.AddRange(tail.Gaps);runs.RemoveAt(runs.Count-1);
                }
            }
            return runs;
        }
        public static List<double> ReadPacketTimes(string path) {
            List<double> times=new List<double>();
            foreach(string line in File.ReadLines(path)) foreach(string part in line.Split('|')) if(part.StartsWith("pts_time=")){
                double value;if(!double.TryParse(part.Substring(9),NumberStyles.Float,CultureInfo.InvariantCulture,out value)) throw new IOException("Output packet has no timestamp.");times.Add(value);
            }
            times.Sort();return times;
        }
        public static void VerifyPacketTimes(string path,List<double> expected) {
            List<double> times=ReadPacketTimes(path);
            if(times.Count!=expected.Count) throw new IOException("Output timestamp count differs from source.");
            for(int i=0;i<times.Count;i++) if(Math.Abs((times[i]-times[0])-(expected[i]-expected[0]))>0.002) throw new IOException("Output frame timing differs at frame "+i);
        }
    }
}
