function Obj(y) {
    this.x = y;
    this.doIt = function(x) { this.x = x; return this; };
}
var o = new Obj(2);
o.doIt(2).doIt(3);
var o2 = new Obj('b');
o2.doIt('fa').doIt('mo');
