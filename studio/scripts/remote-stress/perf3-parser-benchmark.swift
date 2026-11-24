import Foundation
// Only scanner dependency. Full RemoteTouchFrame decoder is not benchmarked.
enum RemoteTouchFrame { static let maximumBytes = 256 }
let vectors: [(String,Data,Bool)] = [
 ("touch", Data(#"{"version":1,"sequence":123,"kind":"touch","x":0.2,"y":0.8}"#.utf8),true),
 ("pedal",Data(#"{"version":6,"sequence":123,"kind":"pedalboard","mask":63,"levels":[0.12,0.34,0.56,1,1,1]}"#.utf8),true),
 ("escaped",Data(#"{"\u0076ersion":1,"sequence":123,"kind":"release"}"#.utf8),true),
 ("duplicate",Data(#"{"version":1,"\u0076ersion":1,"sequence":123,"kind":"release"}"#.utf8),false),
 ("near-cap",Data((#"{"version":1,"sequence":123,"kind":"release","extra":""# + String(repeating:"x",count:180) + "\"}").utf8),true),
 ("bad-array",Data(#"{"version":6,"sequence":123,"kind":"pedalboard","mask":63,"levels":[0.12,0.34,0.56,1,1,]}"#.utf8),false),
 ("oversize",Data(repeating:65,count:257),false),
 ("invalid-utf8",Data([123,34,255,34,58,49,125]),false)
]
func quantile(_ a:[Double],_ q:Double)->Double { let s=a.sorted();return s[max(0,Int(ceil(Double(s.count)*q))-1)] }
// Compare exact key sets, including invalid syntax; scanner validity is NOT full schema validity.
var corpus=vectors.map{$0.1}
for key in ["version","sequence","kind","mask","levels","x","y","\"","\\u0076ersion"] {
 for value in ["0","1","-0","1.0","1e999","true","null","[]","[1,2]","[1,]","{}","\"x\""] {
  corpus.append(Data(("{\""+key+"\":"+value+"}").utf8))
  corpus.append(Data(("{\"version\":1,\""+key+"\":"+value+"}").utf8))
 }
}
for data in corpus {precondition(RemoteFlatJSON.uniqueKeys(data)==CachedRemoteFlatJSON.uniqueKeys(data),"cache mismatch")}
print("equivalence_vectors,\(corpus.count)")
print("name,bytes,variant,accepted,p50_us,p95_us,p99_us,max_us")
let methods:[(String,(Data)->Set<String>?)]=[("actual",RemoteFlatJSON.uniqueKeys),("cached",CachedRemoteFlatJSON.uniqueKeys)]
for (name,data,expected) in vectors {
 var times:[[Double]]=[[],[]];var accepted=[0,0]
 for (_,method) in methods { precondition((method(data) != nil)==expected,name);for _ in 0..<100 {_=method(data)} }
 for i in 0..<3000 { for j in (i.isMultiple(of:2) ? [0,1]:[1,0]) {let start=DispatchTime.now().uptimeNanoseconds;let result=methods[j].1(data);let end=DispatchTime.now().uptimeNanoseconds;times[j].append(Double(end-start)/1000);if result != nil {accepted[j]+=1}} }
 for j in 0..<2 { print("\(name),\(data.count),\(methods[j].0),\(accepted[j]),\(quantile(times[j],0.5)),\(quantile(times[j],0.95)),\(quantile(times[j],0.99)),\(times[j].max()!)") }
}
