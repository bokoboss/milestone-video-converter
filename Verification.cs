using System;
using System.IO;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
namespace PortableVideo {
    public sealed class PacketRecord { public double Pts,Dts; public long Size; public string Hash; }
    public sealed class SampleWindow { public double Start,End; public int Frames; }
    public sealed class PacketManifest {
        public List<PacketRecord> Records=new List<PacketRecord>();
        public static PacketManifest Load(string path) {
            PacketManifest m=new PacketManifest(); double tb=0;
            foreach(string line in File.ReadLines(path)) {
                if(line.StartsWith("#tb 0:")) {string[] r=line.Substring(line.IndexOf(':')+1).Trim().Split('/');tb=double.Parse(r[0],CultureInfo.InvariantCulture)/double.Parse(r[1],CultureInfo.InvariantCulture);continue;}
                if(line.StartsWith("#") || line.Trim().Length==0) continue;
                string[] p=line.Split(',');
                if(p.Length!=6 || tb<=0) throw new IOException("Invalid packet hash manifest.");
                string hash=p[5].Trim();if(hash.Length!=64) throw new IOException("Invalid SHA-256 record.");
                m.Records.Add(new PacketRecord {Dts=long.Parse(p[1])*tb,Pts=long.Parse(p[2])*tb,Size=long.Parse(p[4]),Hash=hash});
            }
            if(m.Records.Count==0) throw new IOException("Empty packet manifest.");return m;
        }
        public PacketManifest Range(int start,int count) {PacketManifest r=new PacketManifest();r.Records.AddRange(Records.GetRange(start,count));return r;}
        public string Digest() {
            using(SHA256 sha=SHA256.Create()) {
                foreach(PacketRecord r in Records) {byte[] b=Encoding.ASCII.GetBytes(r.Size.ToString(CultureInfo.InvariantCulture)+":"+r.Hash+"\n");sha.TransformBlock(b,0,b.Length,b,0);}
                sha.TransformFinalBlock(new byte[0],0,0);return BitConverter.ToString(sha.Hash).Replace("-","").ToLowerInvariant();
            }
        }
        public void Compare(PacketManifest output,bool payload) {
            if(Records.Count!=output.Records.Count) throw new IOException("Video packet count differs.");
            double p=Records[0].Pts,q=output.Records[0].Pts,d=Records[0].Dts,e=output.Records[0].Dts;
            for(int i=0;i<Records.Count;i++) {
                PacketRecord a=Records[i],b=output.Records[i];
                if(payload && (a.Size!=b.Size || a.Hash!=b.Hash)) throw new IOException("Compressed video differs at packet "+i+". Select full decoded verification to investigate parameter-set/container changes.");
                if(Math.Abs((a.Pts-p)-(b.Pts-q))>0.002 || Math.Abs((a.Dts-d)-(b.Dts-e))>0.002) throw new IOException("Packet timing/order differs at packet "+i);
            }
        }
        public void CheckTimes(List<double> expected) {
            List<double> times=new List<double>();foreach(PacketRecord r in Records)times.Add(r.Pts);times.Sort();
            if(times.Count!=expected.Count)throw new IOException("Frame/packet count mismatch.");
            for(int i=0;i<times.Count;i++)if(Math.Abs((times[i]-times[0])-(expected[i]-expected[0]))>0.002)throw new IOException("Packet timestamp mismatch at frame "+i);
        }
        public void Append(PacketManifest other,double offset) {
            double first=double.MaxValue;foreach(PacketRecord r in other.Records)first=Math.Min(first,r.Pts);
            foreach(PacketRecord r in other.Records)Records.Add(new PacketRecord {Pts=r.Pts-first+offset,Dts=r.Dts-first+offset,Hash=r.Hash,Size=r.Size});
        }
        public List<double> Times() {List<double> t=new List<double>();foreach(PacketRecord r in Records)t.Add(r.Pts);t.Sort();return t;}
        public static List<SampleWindow> Windows(List<double> times,double interval) {
            if(times.Count==0)throw new IOException("No sample frames.");
            double first=times[0],last=times[times.Count-1],middle=first+(last-first)/2;
            int mid=times.BinarySearch(middle);if(mid<0)mid=Math.Min(times.Count-1,~mid);middle=times[mid];
            List<double[]> raw=new List<double[]>();
            raw.Add(new double[]{first,first+2});raw.Add(new double[]{middle-1,middle+1});raw.Add(new double[]{last-2,last+0.000001});
            for(int i=1;i<times.Count;i++)if(times[i]-times[i-1]>Math.Max(interval*3,interval+0.1)) {
                raw.Add(new double[]{times[i-1]-2,times[i-1]+0.000001});raw.Add(new double[]{times[i],times[i]+2});
            }
            List<int[]> ranges=new List<int[]>();
            foreach(double[] w in raw) {
                int a=times.BinarySearch(w[0]);if(a<0)a=~a;
                int b=times.BinarySearch(w[1]);if(b<0)b=~b;b--;
                a=Math.Max(0,a);b=Math.Min(times.Count-1,b);
                if(a<=b)ranges.Add(new int[]{a,b});
            }
            ranges.Sort(delegate(int[] a,int[] b){return a[0].CompareTo(b[0]);});
            List<int[]> merged=new List<int[]>();foreach(int[] r in ranges) {
                if(merged.Count>0 && r[0]<=merged[merged.Count-1][1]+1)merged[merged.Count-1][1]=Math.Max(merged[merged.Count-1][1],r[1]);else merged.Add(r);
            }
            List<SampleWindow> result=new List<SampleWindow>();foreach(int[] r in merged)result.Add(new SampleWindow {Start=times[r[0]]-first,End=times[r[1]]-first+0.000001,Frames=r[1]-r[0]+1});return result;
        }
    }
    public sealed class HashProgress {
        private long offset;private bool atStart=true,record;
        public long Count;
        public long Read(string path) {
            if(!File.Exists(path))return Count;
            using(FileStream f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
                f.Position=offset;byte[] buffer=new byte[65536];int n;
                while((n=f.Read(buffer,0,buffer.Length))>0){for(int i=0;i<n;i++) {
                    byte b=buffer[i];if(atStart){record=b!=(byte)'#' && b!=(byte)'\r' && b!=(byte)'\n';atStart=false;}
                    if(b==10){if(record)Count++;atStart=true;}
                }offset+=n;}
            }return Count;
        }
    }
}
