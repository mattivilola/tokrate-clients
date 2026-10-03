/** A pending dialog never prevents opt-out; stale reads cannot undo newer mutations. */
export class AsyncGate {
  epoch = 0;
  pending = 0;
  beginMutation() {
    this.pending++;
    return ++this.epoch;
  }
  finishMutation() {
    this.pending--;
  }
  accepts(epoch: number) {
    return this.pending === 0 && epoch === this.epoch;
  }
  isLatest(epoch: number) {
    return epoch === this.epoch;
  }
}
