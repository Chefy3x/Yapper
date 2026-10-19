import React from "react";
import { Composition } from "remotion";
import {FreshPromo, PROMO_FRAMES} from "./FreshPromo";
import {WalkawayPromo, WALKAWAY_FRAMES} from "./WalkawayPromo";
import {SideAPromo, SIDE_A_FRAMES} from "./SideAPromo";
import {RealFlow} from "./read/RealFlow";
import {TOTAL as REAL_FLOW_FRAMES} from "./read/timing";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="YapperPromo"
        component={FreshPromo}
        durationInFrames={PROMO_FRAMES}
        fps={30}
        width={1920}
        height={1080}
      />
      <Composition
        id="YapperWalkaway"
        component={WalkawayPromo}
        durationInFrames={WALKAWAY_FRAMES}
        fps={30}
        width={1920}
        height={1080}
      />
      <Composition
        id="YapperRealFlow"
        component={RealFlow}
        durationInFrames={REAL_FLOW_FRAMES}
        fps={30}
        width={1920}
        height={1080}
      />
      <Composition
        id="YapperSideA"
        component={SideAPromo}
        durationInFrames={SIDE_A_FRAMES}
        fps={30}
        width={1920}
        height={1080}
      />
    </>
  );
};
