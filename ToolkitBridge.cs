// Compiled in memory by Windows PowerShell; no application executable is installed.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security;
using System.Threading;
using VideoOS.Toolkit;

namespace PortableVideo {
    public sealed class Gop {
        public DateTime Start, End;
        public int Frames;
    }
    public sealed class Timeline {
        public List<Gop> Gops = new List<Gop>();
        public List<long> FrameTicks = new List<long>();
        public DateTime Start, End;
        public long Frames;
        public double FrameInterval;
        public string CompressedPayloadSha256;
    }
    public sealed class Bridge : IDisposable {
        private ToolkitFactory factory = new ToolkitFactory();
        private IToolkit instance;
        private IExportToolkit exporter;
        private Thread thread;
        private volatile bool finished;
        private Exception failure;
        private string source;
        public bool Finished { get { return finished; } }
        public int Progress { get { return exporter == null ? 0 : exporter.GetPercentageCompleted(); } }
        public Bridge(string bank, string table) {
            source = "<toolkit type=\"source\"><provider>mpms</provider><config><table include_archives=\"yes\"><name>" +
                SecurityElement.Escape(table) + "</name><bank><path>" + SecurityElement.Escape(bank) +
                "</path></bank></table></config></toolkit>";
        }
        public Timeline Scan(string cancelPath) {
            Timeline result = new Timeline();
            List<double> intervals = new List<double>();
            DateTime previous = DateTime.MinValue;
            instance = factory.CreateInstance(source);
            IPlaybackSourceToolkit playback = (IPlaybackSourceToolkit)instance;
            ((ISourceToolkit)instance).Connect();
            try {
                string move = playback.MoveFirst().ToString();
                {
                    while (move == "MOVED_OK") {
                        if (File.Exists(cancelPath)) throw new OperationCanceledException();
                        IData data = null;
                        try {
                            if (playback.GetData(out data).ToString() != "DATA_RETRIEVED" || data == null)
                                throw new IOException("Toolkit could not read a database record.");
                            IMediaDataVector vector = data as IMediaDataVector;
                            if (vector == null) throw new System.NotSupportedException("Unsupported database record type: " + data.GetType().Name);
                            IMediaData[] frames = vector.GetVector();
                            if (frames.Length == 0) throw new IOException("Empty media record.");
                            Gop gop = new Gop();
                            foreach (IMediaData frame in frames) {
                                DateTime time = frame.BeginTimeStamp;
                                if (gop.Frames == 0) gop.Start = time;
                                gop.End = time; gop.Frames++; result.Frames++;
                                if (result.Frames == 1) result.Start = time;
                                if (previous != DateTime.MinValue) {
                                    double delta = (time - previous).TotalSeconds;
                                    if (delta <= 0) throw new System.NotSupportedException("Non-increasing source frame timestamps; manual review required.");
                                    if (intervals.Count < 10000) intervals.Add(delta);
                                }
                                previous = time; result.End = time;
                                result.FrameTicks.Add(time.Ticks);
                                if (frame is IDisposable) ((IDisposable)frame).Dispose();
                            }
                            result.Gops.Add(gop);
                        } finally { if (data is IDisposable) ((IDisposable)data).Dispose(); }
                        move = playback.MoveNext().ToString();
                    }
                    if (move != "NOT_MOVED") throw new IOException("Unexpected Toolkit traversal result: " + move);
                    result.CompressedPayloadSha256 = null; // v3 verifies exported packets; no redundant payload copy/hash during timeline scan.
                }
                if (result.Frames == 0) throw new IOException("No video frames in this database.");
                intervals.Sort();
                result.FrameInterval = intervals.Count == 0 ? 0.04 : intervals[intervals.Count / 2];
                return result;
            } finally { factory.DeleteInstance(instance); instance = null; }
        }
        public void StartExport(string path, DateTime begin, DateTime end) {
            string xml = "<toolkit type=\"export\"><provider>mkv</provider><config><file>" + SecurityElement.Escape(path) +
                "</file><span begin=\"" + begin.ToUniversalTime().ToString("o") + "\" end=\"" +
                end.ToUniversalTime().ToString("o") + "\"/><track type=\"video\">" + source + "</track></config></toolkit>";
            instance = factory.CreateInstance(xml);
            exporter = (IExportToolkit)instance;
            thread = new Thread(delegate() {
                IData data = null;
                try {
                    string status = exporter.Export(out data).ToString();
                    if (status != "EXPORT_RESULT_DONE") throw new IOException("Toolkit export: " + status);
                } catch (Exception ex) { failure = ex; }
                finally { if (data is IDisposable) ((IDisposable)data).Dispose(); finished = true; }
            });
            thread.IsBackground = true; thread.Start();
        }
        public void Cancel() { if (exporter != null && !finished) exporter.CancelExport(true); }
        public void CheckExport() { if (failure != null) throw new IOException("Milestone export failed.", failure); }
        public void Dispose() {
            Cancel();
            if (thread != null) thread.Join();
            if (instance != null) { factory.DeleteInstance(instance); instance = null; }
            factory.Dispose();
        }
    }
}


