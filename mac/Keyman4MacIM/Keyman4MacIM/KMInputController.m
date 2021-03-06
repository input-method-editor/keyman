//
//  KMInputController.m
//  Keyman4MacIM
//
//  Created by Serkan Kurt on 29/01/2015.
//  Copyright (c) 2017 SIL International. All rights reserved.
//

#import "KMInputController.h"
#include <Carbon/Carbon.h> /* For kVK_ constants. */

@interface KMInputController ()
@property (nonatomic, strong) NSMutableDictionary *kbData;
//@property (nonatomic, strong) NSDictionary *kmModes;
@property (assign) BOOL willDeleteNullChar;
@end

@implementation KMInputController

const CGKeyCode kProcessPendingBuffer = 0xFF;

//_pendingBuffer contains text that is ready to be sent to the client when all delete-backs are finished.
NSMutableString* _pendingBuffer;
NSUInteger _numberOfPostedDeletesToExpect = 0;
CGKeyCode _keyCodeOfOriginalEvent;
CGEventSourceRef _sourceFromOriginalEvent = nil;
BOOL _contextOutOfDate = YES;

// This flag indicates which mode is being used for replacing already typed text when composing characters
// (i.e., when not using deadkeys). Some apps (and some javascript-based websites, such as Google Docs) do
// not properly deal with calls to insertText calls that replace a range of characters. So for these "legacy"
// apps, we post one or more deletes (i.e., backspace), followed by a special code that tells us we're now
// ready to insert the composed text.
BOOL _legacyMode = NO;
// Some clients (e.g. Chrome) handle the mouse down events before we get a crack at them. For such apps that
// are able to report their current selection location (LibreOffice can't even do that!), we can do some
// checking at the start of the event processing to see if we're probably still in the same place where we
// left off previously.
BOOL _clientSelectionCanChangeUnexpectedly = YES; // REVIEW: Maybe we can get notification from these clients by handling mouseDownOnCharacterIndex.
BOOL _insertCharactersIndividually = NO;
// Because Google Docs can't report its context in any of the browsers (Safari, Chrome, Firefox), we want to
// try to detect it and:
// in Safari, switch to legacy mode
// in Chrome, NOT assume that it needs to re-get the context every time around (which means that if the user
// does mouse-click somewhere else, it could lead to bad behaviour).
// in Firefox, we're already in legacy mode and we do get mouse clicks, so we're already doing the best we can.
NSUInteger _failuresToRetrieveExpectedContext = NSUIntegerMax;
BOOL _forceRemoveSelectionInGoogleDocs = NO;
BOOL _explicitlyDeleteExistingSelectionBeforeInserting = NO;
BOOL _cannnotTrustSelectionLength = NO;
NSRange _previousSelRange;

- (KMInputMethodAppDelegate *)AppDelegate {
    return (KMInputMethodAppDelegate *)[NSApp delegate];
}

- (id)initWithServer:(IMKServer *)server delegate:(id)delegate client:(id)inputClient
{
    self = [super initWithServer:server delegate:delegate client:inputClient];
    if (self) {
        self.AppDelegate.inputController = self;
        if (self.AppDelegate.kvk != nil && self.AppDelegate.alwaysShowOSK)
            [self.AppDelegate showOSK];
    }
    
    return self;
}

- (NSUInteger)recognizedEvents:(id)sender {
    return (NSKeyDownMask | NSLeftMouseDownMask | NSLeftMouseUpMask);
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
    if ([self.AppDelegate debugMode])
        NSLog(@"Event = %@", event);
    
    if (event == nil || sender == nil || self.kmx == nil)
        return NO; // Not sure this can ever happen.
    
    // OSK key feedback from hardware keyboard is disabled
    /*if (event.type == NSKeyDown)
        [self.AppDelegate handleKeyEvent:event];*/
    
    if (event.type == NSLeftMouseDown || event.type == NSLeftMouseUp ) {
//        if (_clientSelectionCanChangeUnexpectedly) {
//            if ([self.AppDelegate debugMode])
//                NSLog(@"WARNING: We are dealing with an app/context where we THINK we shouldn't be getting mouse events, but we just got one!");
//            _clientSelectionCanChangeUnexpectedly = NO;
//        }
        _contextOutOfDate = YES;
        return NO;
    }
    else if (event.type != NSKeyDown)
        return NO; // We ignore NSLeftMouseDragged events (because we'll eventually get a mouse-up).
    else if ((event.modifierFlags & NSEventModifierFlagCommand) == NSEventModifierFlagCommand) {
        // There are a bunch of common navigation/selection command-key combinations, but individual
        // apps may implement specifc commands that also chnage the selection. There is probably no
        // situation where a user could reasonably hope that any dead-keys typed before using a
        // command shortcut would be remembered, so other than an insignificant performance penalty,
        // the only downside to treating all commands as having the potential to change the selection
        // is that some "legacy" apps can't get their context at all.
        if ([self.AppDelegate debugMode])
            NSLog(@"Command key - context needs to be re-gotten.");
        _contextOutOfDate = YES;
        return NO; // We let the client app handle all Command-key events.
    }
    
    if (_legacyMode && event.keyCode == kProcessPendingBuffer)
    {
        if ([self.AppDelegate debugMode])
            NSLog(@"Processing the special %hu code", kProcessPendingBuffer);
        
        NSUInteger length = [self pendingBuffer].length;
        if (length > 0) {
            if ([self.AppDelegate debugMode]) {
                for (NSUInteger ich = 0; ich < length; ich++)
                    NSLog(@"Char %li: '%x'", ich, [[self pendingBuffer] characterAtIndex:ich]);
            }
            NSString* text;
            if (length > 1 && _insertCharactersIndividually) {
                if ([self.AppDelegate debugMode]) {
                    NSLog(@"Using special Google Docs in Chrome logic");
                }
                unichar chars[1];
                chars[0] = [[self pendingBuffer] characterAtIndex:0];
                text = [[NSString alloc] initWithCharacters:chars length:1];
            }
            else {
                text = [self pendingBuffer];
            }
            
            if ([self.AppDelegate debugMode])
                NSLog(@"Inserting text from pending buffer: \"%@\"", text);
            
            [sender insertText:text replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
            _previousSelRange.location += text.length;
            _previousSelRange.length = 0;
            
            if (length > 1 && _insertCharactersIndividually) {
                // Come back for more...
                [_pendingBuffer deleteCharactersInRange:NSMakeRange(0, 1)];
                [self performSelector:@selector(initiatePendingBufferProcessing:) withObject:sender afterDelay:0.1];
            }
            else {
                [self setPendingBuffer:@""];
            }
        }
        else {
            if ([self.AppDelegate debugMode])
                NSLog(@"Error - expected text in pending buffer!");
        }
        return YES;
    }
    
    if (!self.willDeleteNullChar && !_contextOutOfDate && _failuresToRetrieveExpectedContext < 3) {
        if ([self AppDelegate].debugMode) {
            NSLog(@"Checking to see if we're in Google Docs (or some other site that can't give context).");
        }
        NSUInteger bufferLength = self.contextBuffer.length;
        if (bufferLength) {
            NSUInteger location = [sender selectedRange].location;
            
            if (location != NSNotFound && location > 0) {
                NSString *clientContext = [[sender attributedSubstringFromRange:NSMakeRange(0, location)] string];
                if (clientContext == nil || !clientContext.length ||
                    [clientContext characterAtIndex:clientContext.length - 1] !=
                    [self.contextBuffer characterAtIndex:bufferLength - 1]) {
                    _failuresToRetrieveExpectedContext++;
                }
                else {
                    if ([self AppDelegate].debugMode) {
                        NSLog(@"We got what we were expecting from the client. We can stop checking.");
                    }
                    _failuresToRetrieveExpectedContext = NSUIntegerMax;
                }
            }
            else {
                _failuresToRetrieveExpectedContext++;
            }
            
            if (_failuresToRetrieveExpectedContext == 3)
            {
                if ([self AppDelegate].debugMode) {
                    NSLog(@"Detected Google Docs or some other editor that can't provide context. Using legacy mode.");
                }
                _failuresToRetrieveExpectedContext = NSUIntegerMax;
                _legacyMode = YES;
                if (_clientSelectionCanChangeUnexpectedly) {
                    _cannnotTrustSelectionLength = YES;
                    _clientSelectionCanChangeUnexpectedly = NO; // This isn't true (it can change unexpectedly), but we can't get the context, so we pretend/hope it won't.
                    // Google docs in Chrome allows only a single character at a time :-(
                    _insertCharactersIndividually = YES;
                }
            }
        }
    }
    else if ((event.modifierFlags & NSEventModifierFlagCommand) == NSEventModifierFlagCommand)
        return NO; // We ignore any Command-key events.
    
    if ([self.AppDelegate debugMode]) {
        if (_clientSelectionCanChangeUnexpectedly)
            NSLog(@"_clientSelectionCanChangeUnexpectedly = YES");
        else
            NSLog(@"_clientSelectionCanChangeUnexpectedly = NO");
    }
    // The following is needed because some clients (e.g. Chrome & Terminal) handle mouse down events and we
    // never get a crack at them:
    // At the start of the loop before asking the Engine to process the event, unless we still have
    // pending work to do based on posted deletes or the special kProcessPendingBuffer code, check to see if
    // the client still reports a selection that matches the position we would expect based on the length of
    // the context buffer. If not, then reset the context buffer.
    if (_clientSelectionCanChangeUnexpectedly && _numberOfPostedDeletesToExpect == 0 &&
        (_pendingBuffer == nil || _pendingBuffer.length == 0)) {
        NSRange currentSelRange = [sender selectedRange];
        
        if (currentSelRange.location == NSNotFound) {
            _clientSelectionCanChangeUnexpectedly = NO;
        }
        else if ((_previousSelRange.location != currentSelRange.location || _cannnotTrustSelectionLength || _previousSelRange.length != currentSelRange.length)) {
            if ([self.AppDelegate debugMode]) {
                NSLog(@"Client selection may have changed since context was set. Resetting context...");
                NSLog(@"  _previousSelRange.location = %lu", _previousSelRange.location);
                NSLog(@"  _previousSelRange.length = %lu", _previousSelRange.length);
                NSLog(@"  currentSelRange.location = %lu", currentSelRange.location);
                if (_cannnotTrustSelectionLength)
                    NSLog(@"The following cannot be trusted and will be ignored:");
                NSLog(@"  currentSelRange.length = %lu", currentSelRange.length);
            }
            [self updateContextBuffer:sender];
        }
    }
    
    if (_contextOutOfDate)
        [self updateContextBuffer:sender];
    
    BOOL handled = NO;
    BOOL deleteBackPosted = NO;
    NSArray *actions = nil;
    if (!self.willDeleteNullChar) {
        actions = [self.kme processEvent:event];
    }
    
    if ([self.AppDelegate debugMode]) {
        NSLog(@"sender type = %@", NSStringFromClass([sender class]));
        NSLog(@"sender selection range location = %lu", [sender selectedRange].location);
        NSLog(@"actions = %@", actions);
    }
    for (NSDictionary *action in actions) {
        NSString *actionType = [[action allKeys] objectAtIndex:0];
        if ([actionType isEqualToString:Q_STR]) {
            if ([self.AppDelegate debugMode])
                NSLog(@"About to start handling Q_STR action...");
                
            NSString *output = [action objectForKey:actionType];
            if ([self.AppDelegate debugMode])
                NSLog(@"output = %@", output);
            if (deleteBackPosted)
            {
                [self appendPendingBuffer:output];
                if ([self.AppDelegate debugMode])
                    NSLog(@"pendingBuffer = %@", [self pendingBuffer]);
            }
            else {
                NSUInteger nc = [self.contextBuffer deleteLastNullChars];
                // Each null in the context buffer presumably corresponds to a space we inserted when
                // processing the Q_BACK, which we now need to replace with the text we're inserting.
                if (nc > 0) {
                    if ([self.AppDelegate debugMode])
                        NSLog(@"nc = %lu", nc);
                    NSRange selRange = [sender selectedRange];
                    NSUInteger pos = selRange.location;
                    if (pos >= nc && pos != NSNotFound) {
                        if ([self.AppDelegate debugMode]) {
                            NSLog(@"Replacement index = %lu", pos - nc);
                            NSLog(@"Replacement length = %lu", nc);
                        }
                        [sender insertText:output replacementRange:NSMakeRange(pos - nc, nc)];
                        _previousSelRange.location += output.length - nc;
                        _previousSelRange.length = 0;
                    }
                }
                else {
                    // The following commented out code is the code that would make it possible to type over an
                    // existing selection in Word in Safari, but I don't know of a way to distinguish that case
                    // from other contexts in Safari (wherein this code inserts an extra leading space).
//                    if (_explicitlyDeleteExistingSelectionBeforeInserting) {
//                        NSUInteger selLength = [sender selectedRange].length;
//                        if (selLength > 0 && selLength != NSNotFound) {
//                            if ([self.AppDelegate debugMode]) {
//                                NSLog(@"Attempting to delete existing selection of length = %lu by replacing it with a space (which should not actually appear in the text).", selLength);
//                            }
//
//                            [sender insertText:@" " replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
//
//                            if ([self.AppDelegate debugMode])
//                                NSLog(@"Re-posting original (unhandled) code: %d", (int)_keyCodeOfOriginalEvent);
//
//                            CGEventSourceRef sourceFromEvent = CGEventCreateSourceFromEvent([event CGEvent]);
//                            [self postKeyPressToFrontProcess:event.keyCode from:sourceFromEvent];
//                            CFRelease(sourceFromEvent);
//                            return YES;
//                        }
//                    }
                    [sender insertText:output replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
                    _previousSelRange.location += output.length;
                    _previousSelRange.length = 0;
                    
                    // In Google Docs in Safari when there is an existing selection, the inserted characters
                    // stays selected. The following clears the selection.
                    if (_legacyMode && _forceRemoveSelectionInGoogleDocs) {
                        if ([self.AppDelegate debugMode])
                            NSLog(@"Sending Command-Shift-A to clear selection in Google Docs");
                        ProcessSerialNumber psn;
                        GetFrontProcess(&psn);

                        CGEventRef event = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_A, true);
                        //set shift and command keys down for above event
                        CGEventSetFlags(event, kCGEventFlagMaskShift | kCGEventFlagMaskCommand);
                        CGEventPostToPSN(&psn, event);
                        CFRelease(event);

                        event = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_A, false);
                        CGEventSetFlags(event, kCGEventFlagMaskShift | kCGEventFlagMaskCommand);
                        CGEventPostToPSN(&psn, event);
                        CFRelease(event);
                    }
                }
            }
            
            // Even if the characters to insert are pending, we want to append them to the context buffer now.
            // Waiting until they are inserted would probably be safe, but on the off-chance that the engine
            // generates additional actions beyond this current one, we want to be sure that the context reflects
            // the state as it *will* be when all the posted/pending events have been processed.
            [self.contextBuffer appendString:output];
        }
        else if ([actionType isEqualToString:Q_BACK]) {
            if ([self.AppDelegate debugMode])
            {
                NSLog(@"About to start handling Q_BACK action...");
                NSLog(@"contextBuffer = \"%@\"", self.contextBuffer.length?[self.contextBuffer codeString]:@"{empty}");
            }
            [self.contextBuffer deleteLastNullChars];
            NSUInteger dk = [self.contextBuffer deleteLastDeadkeys];
            NSInteger n = [[action objectForKey:actionType] integerValue] - dk;
            NSUInteger dc = [[self.contextBuffer lastNChars:n] deadKeyCount];
            // n is now the number of characters to delete from the context buffer
            // (which could include deadkeys the client doesn't know about).
            [self.contextBuffer deleteLastNChars:n];
            n -= dc;
            
            // n is now the number of characters to delete from the client.
            if (n > 0) {
                if ([self.AppDelegate debugMode])
                {
                    NSLog(@"Q_BACK");
                    NSLog(@"dk = %lu", dk);
                    NSLog(@"n = %li", n);
                    NSLog(@"dc = %lu", dc);
                    if (_legacyMode)
                        NSLog(@"Using Legacy mode.");
                    else
                        NSLog(@"Using Apple IM-compliant mode.");
                }
                NSRange selectedRange = [sender selectedRange];
                NSInteger pos = selectedRange.location;
                if (_legacyMode && self.contextBuffer != nil && (pos == 0 || pos == NSNotFound)) {
                    pos = self.contextBuffer.length + n;
                }
                if ([self.AppDelegate debugMode])
                    NSLog(@"pos = %lu", pos);
                
                if (!_legacyMode && pos >= n && pos != NSNotFound) {
                    NSInteger preCharPos = pos - (n+1);
                    if ((preCharPos) >= 0) {
                        NSUInteger nbrOfPreCharacters;
                        NSString *preChar = nil;
                        
                        // This regex will look back through the context until it finds a *known* base
                        // character because some (non-legacy) apps (e.g., Mail) do not properly handle sending
                        // comining marks on there own via insertText. One potentially negative implication
                        // of this is that if the script should happen to contain characters whose class is
                        // not known, it will skip over them and keep looking, so it could end up using a
                        // longer string of characters than otherwise necessary. This could result in a
                        // mildly jarring visual experience for the user if the app refreshes the diplay
                        // between the time the characters are removed and re-inserted. But presumbly this
                        // algorithm will eventually find either a known base character or get all the way back
                        // to the start of the context, so if it doesn't find a known base character, it will
                        // fall back to just attempting the insert with whatever it does find. I believe this
                        // will always work and should at least work as reliably as the old version of the code,
                        // which always used just a single character regardless of its class.
                        NSError *error = NULL;
                        NSRegularExpression *regexNonCombiningMark = [NSRegularExpression regularExpressionWithPattern:@"\\P{M}" options:NSRegularExpressionCaseInsensitive error:&error];

                        for (nbrOfPreCharacters = 1; YES; nbrOfPreCharacters++, preCharPos--) {
                            preChar = [[sender attributedSubstringFromRange:NSMakeRange(preCharPos, nbrOfPreCharacters)] string];
                            if (!preChar) {
                                if ([self.AppDelegate debugMode]) {
                                    NSLog(@"Client apparently doesn't implement attributedSubstringFromRange. Attempting to get preChar from context...");
                                }
                                if (self.contextBuffer != nil && preCharPos < self.contextBuffer.length) {
                                    preChar = [self.contextBuffer substringWithRange:NSMakeRange(preCharPos, 1)];
                                }
                                if (!preChar)
                                    break;
                            }
                            if ([self.AppDelegate debugMode])
                                NSLog(@"Testing preChar: %@", preChar);

                            if ([regexNonCombiningMark numberOfMatchesInString:preChar options:NSMatchingAnchored range:NSMakeRange(0, 1)] > 0)
                                break;
                            if (preCharPos == 0) {
                                if ([self.AppDelegate debugMode]) {
                                    NSLog(@"Failed to find a base character!");
                                }
                                break;
                            }
                            if ([self.AppDelegate debugMode]) {
                                NSLog(@"Have not yet found a base character. nbrOfPreCharacters = %lu", nbrOfPreCharacters);
                            }
                        }
                        if (preChar) {
                            if ([self.AppDelegate debugMode]) {
                                NSLog(@"preChar (to insert at %lu) = \"%@\"", preCharPos, preChar);
                            }
                            [sender insertText:preChar replacementRange:NSMakeRange(preCharPos, n+nbrOfPreCharacters)];
                        }
                        else {
                            if ([self.AppDelegate debugMode]) {
                                NSLog(@"Switching to legacy mode - client apparently doesn't implement attributedSubstringFromRange and no previous character in context buffer.");
                            }
                            _legacyMode = YES; // client apparently doesn't implement attributedSubstringFromRange.
                        }
                    }
                    else {
                        if ([self.AppDelegate debugMode])
                            NSLog(@"No previous character to use for replacement - replacing range with space");
                        [sender insertText:@" " replacementRange:NSMakeRange(pos - n, n)];
                        [self.contextBuffer appendNullChar];
                    }
                }
                if (_legacyMode && pos >= n) {
                    // n is now the number of delete-backs we need to post (plus one more if there is selected text)
                    if ([self.AppDelegate debugMode]) {
                        NSLog(@"Legacy mode: calling deleteBack");
                        if (_cannnotTrustSelectionLength)
                            NSLog(@"Cannot trust client to report accurate selection length - assuming no selection.");
                    }
                    
                    // Note: If pos is "not found", most likely the client can't accurately report the location. This might be
                    // dangerous, but for now let's go ahead and attempt to delete the characters we think should be there.
                    if (_pendingBuffer != nil && [[self pendingBuffer] length] > 0) {
                        NSException* exception = [NSException
                                                  exceptionWithName:@"InvalidOperationException"
                                                  reason:@"Cannot process subsequent Q_BACK after Q_STR"
                                                  userInfo:nil];
                        @throw exception;
                    }
                    
                    if (!_cannnotTrustSelectionLength && selectedRange.length > 0)
                        n++; // First delete-back will delete the existing selection.
                    [self deleteBack:n for:event];
                    deleteBackPosted = YES;
                    
                    CFRelease(_sourceFromOriginalEvent);
                    _sourceFromOriginalEvent = nil;
                }
            }
        }
        else if ([actionType isEqualToString:Q_DEADKEY]) {
            [self.contextBuffer deleteLastNullChars];
            NSUInteger x = [[action objectForKey:actionType] unsignedIntegerValue];
            [self.contextBuffer appendDeadkey:x];
        }
        else if ([actionType isEqualToString:Q_NUL]) {
            continue;
        }
        else if ([actionType isEqualToString:Q_RETURN]) {
//            if (_legacyMode)
//                _previousSelRange = [sender selectedRange];
            return YES;
        }
        else if ([actionType isEqualToString:Q_BEEP]) {
            [[NSSound soundNamed:@"Tink"] play];
        }
        
        handled = YES;
    }
    
    // Apply context changes if not handled
    if (!handled) {
        NSUInteger nc = [self.contextBuffer deleteLastNullChars];
        if (nc > 0) {
            if ([self.AppDelegate debugMode])
                NSLog(@"Deleted %li null characters from context buffer", nc);
            // This can presumably only happen if a previous event resulted in a chain of
            // actions that had a Q_BACK not followed by a Q_STR (assuming that can happen).
            // REVIEW: Need to test this scenario in Atom and Googe Docs in Safari
            self.willDeleteNullChar = YES;
            [self deleteBack:nc for:event];
            _keyCodeOfOriginalEvent = event.keyCode;

            return YES;
        }
        
        NSString* charactersToAppend = nil;
        BOOL updateEngineContext = YES;
        unsigned short keyCode = event.keyCode;
        switch (keyCode) {
            case kVK_Delete:
                if ([self.AppDelegate debugMode]) {
                    NSLog(@"Processing an unhandled delete-back...");
                    NSLog(@"_numberOfPostedDeletesToExpect = %lu", _numberOfPostedDeletesToExpect);
                }
                
                // If we have pending characters to insert following the delete-back, then
                // the context buffer has already been properly set to reflect the deletions.
                if ((_legacyMode && (_pendingBuffer == nil || _pendingBuffer.length == 0)) ||
                    (!_legacyMode && (!self.willDeleteNullChar)))
                {
                    // Backspace clears last "real" character from buffer, plus any surrounding deadkeys
                    [self.contextBuffer deleteLastDeadkeys];
                    [self.contextBuffer deleteLastNChars:1];
                    if (_legacyMode) {
                        _previousSelRange.location -= 1;
                        _previousSelRange.length = 0;
                    }
                    [self.contextBuffer deleteLastDeadkeys];
                }
                if (_numberOfPostedDeletesToExpect > 0) {
                    if (--_numberOfPostedDeletesToExpect == 0) {
                        if ([self.AppDelegate debugMode])
                            NSLog(@"Processing final posted delete-back...");
                        
                        self.willDeleteNullChar = NO;
                        if (_legacyMode && _pendingBuffer != nil && _pendingBuffer.length > 0) {
                            if ([self.AppDelegate debugMode])
                                NSLog(@"Posting special code to tell IM to insert characters from pending buffer.");
                            [self performSelector:@selector(initiatePendingBufferProcessing:) withObject:sender afterDelay:0.1];
                        }
                        else {
                            if ([self.AppDelegate debugMode]) {
                                NSLog(@"Re-posting original (unhandled) code: %d", (int)_keyCodeOfOriginalEvent);
                            }
                            [self postKeyPressToFrontProcess:_keyCodeOfOriginalEvent from:_sourceFromOriginalEvent];
                            _keyCodeOfOriginalEvent = 0;
                            CFRelease(_sourceFromOriginalEvent);
                            _sourceFromOriginalEvent = nil;
                        }
                        updateEngineContext = NO;
                    }
                }
                else {
                    self.willDeleteNullChar = NO;
                }
                break;
                
            case kVK_LeftArrow:
                // Marc has suggested that it's better to just let it be dumb. Too many potential pitfalls
                // trying to guess where in the context we ended up after a left arrow.
//                if (_legacyMode && self.contextBuffer.length) {
//                    NSUInteger flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
//                    if ([self.AppDelegate debugMode])
//                        NSLog(@"Legacy app Left arrow. flags = 0x%02x", (int)flags);
//                    if ((flags ^ NSEventModifierFlagShift) == 0) {
//                        [self.contextBuffer deleteLastNChars:1];
//                        if ([self.AppDelegate debugMode])
//                            NSLog(@"Removed one character from context.");
//                        break;
//                    }
//                }
                /* FALLTHROUGH */
            case kVK_RightArrow:
            case kVK_UpArrow:
            case kVK_DownArrow:
            case kVK_Home:
            case kVK_End:
            case kVK_PageUp:
            case kVK_PageDown:
                _contextOutOfDate = YES;
                updateEngineContext = NO;
                break;
                
            case kVK_Return:
            case kVK_ANSI_KeypadEnter:
                charactersToAppend = @"\n";
                break;
                
            default:
                {
                    unichar ch = [event.characters characterAtIndex:0];
                    // REVIEW: Is ch ever != keyCode? Is there ever more than one character in event.characters?
                    if (keyCode < 0x33 || (ch >= 0x2A && ch <= 0x39)) { // Main keys, Numpad char range, normal punctuation
                        charactersToAppend = event.characters;
                    }
                    else {
                        // Other keys
                    }
                }
                break;
        }
        if (charactersToAppend != nil) {
            if ([self.AppDelegate debugMode]) {
                NSLog(@"Adding \"%@\" to context buffer", charactersToAppend);
            }
            [self.contextBuffer appendString:charactersToAppend];
            if (_legacyMode) {
                _previousSelRange.location += charactersToAppend.length;
                _previousSelRange.length = 0;
            }
        }
        
        if (updateEngineContext) {
            [self.kme setContextBuffer:self.contextBuffer];
        }
    }
    
    if ([self.AppDelegate debugMode]) {
        NSLog(@"handledEvent: %@", handled?@"YES":@"NO");
        if (_contextOutOfDate)
            NSLog(@"Context now out of date.");
        else
            NSLog(@"contextBuffer = \"%@\"", self.contextBuffer.length?[self.contextBuffer codeString]:@"{empty}");
        NSLog(@"kme.contextBuffer = \"%@\"", self.kme.contextBuffer.length?[self.kme.contextBuffer codeString]:@"{empty}");
        NSRange range = [sender markedRange];
        NSLog(@"sender.markedRange.location = %lu", range.location);
        NSLog(@"sender.markedRange.length = %lu", range.length);
        range = [sender selectedRange];
        NSLog(@"sender.selectedRange.location = %lu", range.location);
        if (_cannnotTrustSelectionLength)
            NSLog(@"The following cannot be trusted and will be ignored:");
        NSLog(@"sender.selectedRange.length = %lu", range.length);
        NSLog(@"***");
    }
    
// Seems we can't do it this way because (at least for "legacy mode" apps, the selection range doesn't get updated
// until after we return from this method.
//    if (_legacyMode)
//        _previousSelRange = [sender selectedRange];
    return handled;
}

- (void)activateServer:(id)sender {
    [sender overrideKeyboardWithKeyboardNamed:@"com.apple.keylayout.US"];

    NSRunningApplication *currApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    NSString *clientAppId = [currApp bundleIdentifier];
    if ([self.AppDelegate debugMode])
        NSLog(@"New active app %@", clientAppId);
    _previousSelRange = NSMakeRange(NSNotFound, NSNotFound);
    _clientSelectionCanChangeUnexpectedly = YES;
    _forceRemoveSelectionInGoogleDocs = NO;
    _explicitlyDeleteExistingSelectionBeforeInserting = NO;
    _cannnotTrustSelectionLength = NO;
    _insertCharactersIndividually = NO;
    // REVIEW: Should this list be in a info.plist file
    // Use a table of known apps to decide whether or not to operate in legacy mode
    // and whether or not to follow calls to setMarkedText with calls to insertText.
    if ([clientAppId isEqual: @"com.google.Chrome"] ||
        [clientAppId isEqual: @"org.mozilla.firefox"] ||
        [clientAppId isEqual: @"com.github.atom"] ||
        [clientAppId isEqual: @"com.collabora.libreoffice-free"] ||
        [clientAppId isEqual: @"com.axosoft.gitkraken"] ||
        [clientAppId isEqual: @"org.sil.app.builder.scripture.ScriptureAppBuilder"] ||
        [clientAppId isEqual: @"org.sil.app.builder.reading.ReadingAppBuilder"] ||
        [clientAppId isEqual: @"org.sil.app.builder.dictionary.DictionaryAppBuilder"] ||
        [clientAppId isEqual: @"com.microsoft.Word"]
        /*||[clientAppId isEqual: @"ro.sync.exml.Oxygen"] - Oxygen has worse problems */) {
        _legacyMode = YES;
        if ([self.AppDelegate debugMode])
            NSLog(@"Using legacy mode for this app.");
    }
    else {
        _legacyMode = NO;
    }
    
    //    if ([clientAppId isEqual: @"com.google.Chrome"] ||
    //        [clientAppId isEqual: @"com.apple.Terminal"] ||
    //        [clientAppId isEqual: @"com.apple.dt.Xcode"]) {
    //        _clientSelectionCanChangeUnexpectedly = YES;
    //    }
    
        if ([clientAppId isEqual: @"com.github.atom"]) {
            // This isn't true (the context can change unexpectedly), but we can't get the context,
            // so we pretend/hope it won't.
            _clientSelectionCanChangeUnexpectedly = NO;
        }
    
    // Most things in Safari work well using the normal way, but Google Docs doesn't.
    if ([clientAppId isEqual: @"com.google.Chrome"] ||
        [clientAppId isEqual: @"com.apple.Safari"] ||
        [clientAppId isEqual: @"org.mozilla.firefox"]) {
        _failuresToRetrieveExpectedContext = 0;
        _forceRemoveSelectionInGoogleDocs = [clientAppId isEqual: @"com.apple.Safari"];
        //_explicitlyDeleteExistingSelectionBeforeInserting = [clientAppId isEqual: @"com.apple.Safari"];
    }
    else {
        _failuresToRetrieveExpectedContext = NSUIntegerMax;
    }
    
    if (_numberOfPostedDeletesToExpect > 0 || (_pendingBuffer != nil && _pendingBuffer.length > 0) ||
        _keyCodeOfOriginalEvent != 0 || _sourceFromOriginalEvent != nil)
    {
        if ([self.AppDelegate debugMode]) {
            NSLog(@"ERROR: new app activated before previous app finished processing pending events!");
            NSLog(@"  _numberOfPostedDeletesToExpect = %lu", _numberOfPostedDeletesToExpect);
            NSLog(@"  pendingBuffer = \"%@\"", _pendingBuffer == nil ? @"(NIL)" : (NSString*)[self pendingBuffer]);
            NSLog(@"  _keyCodeOfOriginalEvent = %hu", _keyCodeOfOriginalEvent);
        }
        _numberOfPostedDeletesToExpect = 0;
        _pendingBuffer = nil;
        _keyCodeOfOriginalEvent = 0;
        if (_sourceFromOriginalEvent != nil) {
            CFRelease(_sourceFromOriginalEvent);
            _sourceFromOriginalEvent = nil;
        }
    }

    _contextOutOfDate = YES;
}

- (void)deactivateServer:(id)sender {
    if ([self.AppDelegate debugMode]) {
        NSLog(@"*** deactivateServer ***");
        NSLog(@"sender: %@", sender);
        NSLog(@"***");
    }
}

/*
- (NSDictionary *)modes:(id)sender {
    if ([self.AppDelegate debugMode])
        NSLog(@"*** Modes ***");
    if (_kmModes == nil) {
        NSDictionary *amhMode = [[NSDictionary alloc] initWithObjectsAndKeys:@"keyman.png", kTSInputModeAlternateMenuIconFileKey,
                                 [NSNumber numberWithBool:YES], kTSInputModeDefaultStateKey,
                                 [NSNumber numberWithBool:YES], kTSInputModeIsVisibleKey,
                                 @"A", kTSInputModeKeyEquivalentKey,
                                 [NSNumber numberWithInteger:4608], kTSInputModeKeyEquivalentModifiersKey,
                                 [NSNumber numberWithBool:YES], kTSInputModeDefaultStateKey,
                                 @"keyman.png", kTSInputModeMenuIconFileKey,
                                 @"keyman.png", kTSInputModePaletteIconFileKey,
                                 [NSNumber numberWithBool:YES], kTSInputModePrimaryInScriptKey,
                                 @"smUnicodeScript", kTSInputModeScriptKey,
                                 @"amh", @"TISIntendedLanguage", nil];
        
        NSDictionary *hinMode = [[NSDictionary alloc] initWithObjectsAndKeys:@"keyman.png", kTSInputModeAlternateMenuIconFileKey,
                                 [NSNumber numberWithBool:YES], kTSInputModeDefaultStateKey,
                                 [NSNumber numberWithBool:YES], kTSInputModeIsVisibleKey,
                                 @"H", kTSInputModeKeyEquivalentKey,
                                 [NSNumber numberWithInteger:4608], kTSInputModeKeyEquivalentModifiersKey,
                                 [NSNumber numberWithBool:YES], kTSInputModeDefaultStateKey,
                                 @"keyman.png", kTSInputModeMenuIconFileKey,
                                 @"keyman.png", kTSInputModePaletteIconFileKey,
                                 [NSNumber numberWithBool:YES], kTSInputModePrimaryInScriptKey,
                                 @"smUnicodeScript", kTSInputModeScriptKey,
                                 @"hin", @"TISIntendedLanguage", nil];
        
        NSDictionary *modeList = [[NSDictionary alloc] initWithObjectsAndKeys:amhMode, @"com.apple.inputmethod.amh", hinMode, @"com.apple.inputmethod.hin", nil];
        NSArray *modeOrder = [[NSArray alloc] initWithObjects:@"com.apple.inputmethod.amh", @"com.apple.inputmethod.hin", nil];
        _kmModes = [[NSDictionary alloc] initWithObjectsAndKeys:modeList, kTSInputModeListKey,
                               modeOrder, kTSVisibleInputModeOrderedArrayKey, nil];
    }

    return _kmModes;
}
*/

- (NSMenu *)menu {
    return self.AppDelegate.menu;
}

- (KMEngine *)kme {
    return self.AppDelegate.kme;
}

- (KMXFile *)kmx {
    return self.AppDelegate.kmx;
}

- (NSMutableString *)contextBuffer {
    if (_contextOutOfDate) {
        NSException* exception = [NSException
                                  exceptionWithName:@"InvalidOperationException"
                                  reason:@"Attempt to access out-of-date context."
                                  userInfo:nil];
        @throw exception;
    }
    return self.AppDelegate.contextBuffer;
}

- (void)updateContextBuffer:(id)sender {
    if ([self.AppDelegate debugMode]) {
        NSLog(@"*** updateContextBuffer ***");
        NSLog(@"sender: %@", sender);
    }
    
    NSRange selRange = [sender selectedRange];
    NSUInteger len = [sender length];
    if ([self.AppDelegate debugMode]) {
        NSLog(@"selRange.location: %lu", (unsigned long)selRange.location);
        NSLog(@"sender length: %lu", len);
    }
    
    if (selRange.location == NSNotFound) {
        // REVIEW: For now, if the client always reports its selectedRange as "not found", we're stuck assuming that any
        // previous context we've built up is indeed current. This may be totally untrue, but if the client can't report
        // its location, there's no point trying to check to see if it changed unexpectedly.
        _clientSelectionCanChangeUnexpectedly = NO;
    }
    else {
        len = selRange.location;
    }

    NSString *preBuffer = [[sender attributedSubstringFromRange:NSMakeRange(0, len)] string];
    if ([self.AppDelegate debugMode]) {
        NSLog(@"preBuffer = \"%@\"", preBuffer);
        if (preBuffer.length)
            NSLog(@"First character: '%x'", [preBuffer characterAtIndex:0]);
        else
            NSLog(@"preBuffer has a length of 0");
    }
    // REVIEW: If there is ever a situation where preBuffer gets some text but the client reports its
    // selectedRange as not found, we probably can't reliably assume that the current location is really
    // at the end of the "preBuffer", so maybe we just need to assume no context.
    [self.AppDelegate setContextBuffer:preBuffer.length?[NSMutableString stringWithString:preBuffer]:nil];
    _contextOutOfDate = NO;
    if ([self.AppDelegate debugMode]) {
        NSLog(@"contextBuffer = \"%@\"", self.contextBuffer.length?[self.contextBuffer codeString]:@"{empty}");
        NSLog(@"***");
    }
    _previousSelRange = selRange;
}

- (void)menuAction:(id)sender {
    NSMenuItem *mItem = [sender objectForKey:kIMKCommandMenuItemName];
    NSInteger itag = mItem.tag;
    if (itag == 2) {
        // Using `showConfigurationWindow` instead of `showPreferences:` because `showPreferences:` is missing in
        // High Sierra (confirmed missing up to 10.13.1). See: https://bugreport.apple.com/web/?problemID=35422518
        [self.AppDelegate showConfigurationWindow];
    }
    else if (itag == 3) {
        [self.AppDelegate showOSK];
    }
    else if (itag == 4) {
        [self.AppDelegate showAboutWindow];
    }
    else if (itag >= 1000) {
        NSMenuItem *keyboards = [self.AppDelegate.menu itemWithTag:1];
        for (NSMenuItem *item in keyboards.submenu.itemArray) {
            if (item.tag == itag)
                [item setState:NSOnState];
            else
                [item setState:NSOffState];
        }
        
        NSString *path = [self.AppDelegate.activeKeyboards objectAtIndex:itag%1000];
        KMXFile *kmx = [[KMXFile alloc] initWithFilePath:path];
        [self.AppDelegate setKmx:kmx];
        KVKFile *kvk = nil;
        NSDictionary *kmxInfo = [KMXFile infoDictionaryFromFilePath:path];
        NSString *kvkFilename = [kmxInfo objectForKey:kKMVisualKeyboardKey];
        if (kvkFilename != nil) {
            NSString *kvkFilePath = [self.AppDelegate kvkFilePathFromFilename:kvkFilename];
            if (kvkFilePath != nil)
                kvk = [[KVKFile alloc] initWithFilePath:kvkFilePath];
        }
        [self.AppDelegate setKvk:kvk];
        [self.AppDelegate setKeyboardName:[kmxInfo objectForKey:kKMKeyboardNameKey]];
        [self.AppDelegate setKeyboardIcon:[kmxInfo objectForKey:kKMKeyboardIconKey]];
        [self.AppDelegate setContextBuffer:nil];
        [self.AppDelegate setSelectedKeyboard:path];
        if (kvk != nil && self.AppDelegate.alwaysShowOSK)
            [self.AppDelegate showOSK];
    }
}

// Return the pending buffer.  If it is NIL create it.
-(NSMutableString*)pendingBuffer;
{
    if ( _pendingBuffer == nil ) {
        _pendingBuffer = [[NSMutableString alloc] init];
    }
    return _pendingBuffer;
}

// Change the pending buffer.
-(void)setPendingBuffer:(NSString*)string
{
    NSMutableString*        buffer = [self pendingBuffer];
    [buffer setString:string];
}

// Append to (creating if necessary) the pending buffer.
-(void)appendPendingBuffer:(NSString*)string
{
    NSMutableString*        buffer = [self pendingBuffer];
    [buffer appendString:string];
}

- (void)sendEvent:(NSEvent *)event {
    ProcessSerialNumber psn;
    GetFrontProcess(&psn);
    
    CGEventSourceRef source = CGEventCreateSourceFromEvent([event CGEvent]);
    CGEventRef keyDownEvent = CGEventCreateKeyboardEvent(source, event.keyCode, true);
    CGEventRef keyUpEvent = CGEventCreateKeyboardEvent(source, event.keyCode, false);
    
    CGEventPostToPSN(&psn, keyDownEvent);
    CGEventPostToPSN(&psn, keyUpEvent);
    
    CFRelease(source);
    CFRelease(keyDownEvent);
    CFRelease(keyUpEvent);
}

- (void)deleteBack:(NSUInteger)count for:(NSEvent *) event {
    _numberOfPostedDeletesToExpect = count;
    CGEventRef ev;
    _sourceFromOriginalEvent = CGEventCreateSourceFromEvent([event CGEvent]);

    for (int db = 0; db < count; db++)
    {
        if ([self.AppDelegate debugMode])
            NSLog(@"Posting a delete (down/up) at kCGHIDEventTap.");
        
        ev = CGEventCreateKeyboardEvent (_sourceFromOriginalEvent, kVK_Delete, true);//delete-back down
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
        ev = CGEventCreateKeyboardEvent (_sourceFromOriginalEvent, kVK_Delete, false); //delete-back up
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
    }
}

- (void)initiatePendingBufferProcessing:(id)sender {
    [self postKeyPressToFrontProcess:kProcessPendingBuffer from:NULL];
}

- (void)postKeyPressToFrontProcess:(CGKeyCode)code from:(CGEventSourceRef) source {
    ProcessSerialNumber psn;
    GetFrontProcess(&psn);
    
    CGEventRef event = CGEventCreateKeyboardEvent(source, code, true);
    CGEventPostToPSN(&psn, event);
    CFRelease(event);
    
    if (code != kProcessPendingBuffer) { // special 0xFF code is not a real key-press, so no "up" is needed
        event = CGEventCreateKeyboardEvent(source, code, false);
        CGEventPostToPSN(&psn, event);
        CFRelease(event);
    }
}

@end
