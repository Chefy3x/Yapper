import { Config } from "@remotion/cli/config";

Config.setVideoImageFormat("jpeg");
Config.setOverwriteOutput(true);
// Generous budget so a busy machine can't time out the font/asset delayRender.
Config.setDelayRenderTimeoutInMilliseconds(120000);
