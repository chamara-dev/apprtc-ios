/*
 *  Copyright 2015 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "ARDStatsView.h"

#import "RTCStatsReport.h"
#import <AppRTC/ARDStatsBuilder.h>

@implementation ARDStatsView {
  UILabel *_statsLabel;
  ARDStatsBuilder *_statsBuilder;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
      [self initStatsView];
  }
  return self;
}

- (void) initStatsView{
    
    _statsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statsLabel.numberOfLines = 0;
    _statsLabel.font = [UIFont systemFontOfSize:12];
    _statsLabel.adjustsFontSizeToFitWidth = YES;
    _statsLabel.minimumScaleFactor = 0.6;
    _statsLabel.textColor = [UIColor greenColor];
    [self addSubview:_statsLabel];
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:.6];
    _statsBuilder = [[ARDStatsBuilder alloc] init];
}


- (void) awakeFromNib
{
    [super awakeFromNib];
    [self initStatsView];
}

- (void)setStats:(NSArray *)stats {
  for (RTCStatsReport *report in stats) {
    [_statsBuilder parseStatsReport:report];
  }
  _statsLabel.text = _statsBuilder.statsString;
}

- (void)layoutSubviews {
  _statsLabel.frame = self.bounds;
}

- (CGSize)sizeThatFits:(CGSize)size {
  return [_statsLabel sizeThatFits:size];
}

@end
