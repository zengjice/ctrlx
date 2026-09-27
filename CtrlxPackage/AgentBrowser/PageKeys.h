#pragma once
#import <Foundation/Foundation.h>

// Page-scoped keys only. No printable-text backdoor, clipboard, browser chrome
// shortcuts or caller-defined CDP fields. Text entry belongs to type/fill.
inline NSDictionary* PageKeyDown(NSString* shortcut) {
  if (![shortcut isKindOfClass:NSString.class] || shortcut.length > 64) return nil;
  NSArray<NSString*>* parts = [shortcut componentsSeparatedByString:@"+"];
  if (parts.count == 0 || parts.count > 5) return nil;
  NSDictionary* modifiers = @{@"Alt": @1, @"Control": @2, @"Ctrl": @2,
                              @"Meta": @4, @"Command": @4, @"Shift": @8};
  int mask = 0;
  for (NSUInteger i = 0; i + 1 < parts.count; ++i) {
    NSNumber* bit = modifiers[parts[i]];
    if (!bit || (mask & bit.intValue)) return nil;
    mask |= bit.intValue;
  }
  NSDictionary* keys = @{
    @"Enter": @[@"Enter", @"Enter", @13, @"\r"], @"Tab": @[@"Tab", @"Tab", @9, @""],
    @"Escape": @[@"Escape", @"Escape", @27, @""], @"Backspace": @[@"Backspace", @"Backspace", @8, @""],
    @"Delete": @[@"Delete", @"Delete", @46, @""], @"Space": @[@" ", @"Space", @32, @" "],
    @"ArrowLeft": @[@"ArrowLeft", @"ArrowLeft", @37, @""], @"ArrowRight": @[@"ArrowRight", @"ArrowRight", @39, @""],
    @"ArrowUp": @[@"ArrowUp", @"ArrowUp", @38, @""], @"ArrowDown": @[@"ArrowDown", @"ArrowDown", @40, @""],
    @"Home": @[@"Home", @"Home", @36, @""], @"End": @[@"End", @"End", @35, @""],
    @"PageUp": @[@"PageUp", @"PageUp", @33, @""], @"PageDown": @[@"PageDown", @"PageDown", @34, @""],
  };
  NSString* name = parts.lastObject;
  NSArray* fields = keys[name];
  if ([name isEqual:@"A"] && (mask == 4 || mask == 2)) fields = @[@"a", @"KeyA", @65, @""];
  if (!fields) return nil;
  NSString* text = (mask & 7) ? @"" : fields[3];
  NSMutableDictionary* result = [@{@"type": text.length ? @"keyDown" : @"rawKeyDown",
      @"key": fields[0], @"code": fields[1], @"windowsVirtualKeyCode": fields[2], @"modifiers": @(mask)} mutableCopy];
  if (text.length) result[@"text"] = text;
  if ([name isEqual:@"A"] && mask == 4) result[@"commands"] = @[@"selectAll"];
  return result;
}
