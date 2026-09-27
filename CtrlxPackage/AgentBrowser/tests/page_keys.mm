#import "../PageKeys.h"
#include <cassert>
#include <cstdio>

int main() { @autoreleasepool {
  assert([PageKeyDown(@"Enter")[@"text"] isEqual:@"\r"]);
  assert([PageKeyDown(@"Shift+Tab")[@"modifiers"] intValue] == 8);
  assert([PageKeyDown(@"Meta+A")[@"commands"] isEqual:@[@"selectAll"]]);
  assert([PageKeyDown(@"Control+ArrowLeft")[@"modifiers"] intValue] == 2);
  assert([PageKeyDown(@"Alt+Shift+ArrowRight")[@"modifiers"] intValue] == 9);
  for (NSString* key in @[@"Tab", @"Escape", @"Space", @"Backspace", @"Delete", @"Home", @"End", @"PageUp", @"PageDown",
                          @"ArrowLeft", @"ArrowRight", @"ArrowUp", @"ArrowDown"])
    assert(PageKeyDown(key));
  for (NSString* key in @[@"", @"A", @"a", @"Meta+V", @"Meta+C", @"Meta+Q", @"F12", @"Shift+Shift+Tab",
                          @"Ctrl+Control+A", @"Meta+Shift+A", @"Unknown+Enter", @"Enter+", @"+Enter"])
    assert(!PageKeyDown(key));
  assert(!PageKeyDown(nil));
  assert(!PageKeyDown((NSString*)@12));
  puts("PASS: bounded page keys, modifiers, select-all and forbidden shortcuts");
} }
