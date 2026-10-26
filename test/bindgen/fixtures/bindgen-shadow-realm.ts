import { bindgen } from "bun:internal-for-testing";

export function holdSharedCounter(initial: number): number {
  const counter = new bindgen.SharedCounter(initial);
  bindgen.SharedCounter.holdForRealmTest(counter);
  if (bindgen.SharedCounter.identity(counter) !== counter) throw new Error("ShadowRealm identity was not stable");
  return counter.value;
}

export function incrementHeldSharedCounter(delta: number): number {
  const first = bindgen.SharedCounter.heldForRealmTest() as InstanceType<typeof bindgen.SharedCounter>;
  const second = bindgen.SharedCounter.heldForRealmTest();
  if (first !== second) throw new Error("ShadowRealm wrapper cache missed");
  return first.increment(delta);
}
