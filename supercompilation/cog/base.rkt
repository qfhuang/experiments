#lang racket

(require "util.rkt")

(data value
  (lam (body env))
  (sym (name))
  (pair (l r))
  (uno ()))

(data term
  (val (x))
  (bound (idx))
  (app (proc arg))
  (if-eq (sym0 sym1 true false))
  (pair-left (x))
  (pair-right (x))
  (let-rec (defs body)))

(data one-hole
  ; value
  (oh-pair-l (r))
  (oh-pair-r (l))
  ; term
  (oh-app-proc (arg))
  (oh-app-arg (proc))
  (oh-if-eq-0 (sym1 true false))
  (oh-if-eq-1 (sym0 true false))
  (oh-pair-left ())
  (oh-pair-right ()))

; TODO
; eager and lazy CBV operational semantics
;   CBV describes observable semantics while lazy/eager describes operational strategy
; eager CBV
;   constructors with args need to save one-hole contexts
;   all terms in focus are evaluated to completion with result values being catalogued
; lazy CBV
;   constructors with args do not save any one-hole contexts
;     they can punt on evaluating their args
;     punted terms are paired with current environment and catalogued as eval obligations
;   rewinding to evaluate an obligation
;     pop catalog entries until desired key is found
;     save popped entries (in reverse) with old context
;     begin evaluating a new state with the remaining catalog
;       (state clg-oblig-term (return-context (old-cont old-env reversed-entries)) clg-oblig-env)
;     when returning to former context, re-push its entries onto the new catalog
;   the catalog as described is actually a special case of a more general 'effect log'
;     entry types can be added for memory allocation and writes
; given a catalog partitioning at any event boundary: members of older part do not depend on members of newer
;   minimize duplication when splitting worlds around a hypothetical equality
;     assumption boundary must be made before any key that would depend on it
;       given key D being guessed
;         assumption entry must be made before first E depending on D's value
;         there may be entries between D and its assumption entry
;           this would be because they depend on D's effects, but don't depend on D's value
;       if made earlier than existing assumption, must split the splits
;         this will happen with out-of-order case analysis on opaque values:
;           first, case-analysis occurs on some D that happens to depend on C
;           later, in one branch of (case D), retroactive case-analysis occurs on C
;           the case-analysis on C must be pulled above that of D
;             C's assumption entry must be made earlier than D's entry
;             new split muts be made earlier than existing split, duplicating that split
;             some waste produced (hopefully only temporarily) for the branch of D not analyzing C
;       older keys definitely don't depend on assumption and make up the old region
;       newer keys that happen to also not depend on assumption may be moved across it into the old region
;         moving across also requires no effect dependencies
;       old region ends up shared by both hypothetical worlds
;   cleaning up after a transformation attempt on a subterm
;     when producing result, only need to garbage collect entries newer than the subterm
;   there should be a single key allocator so that every value, even across partitions/worlds, has a unique key
;     when partitioning based on hypothetical equality, copy all keys dependent on assumed value
;       when re-combining worlds, new world only contributes keys newer than split
; assumptions in effect log mark when the world split
;   new world not responsible for old effects, though may evaluate them under assumptions to see what they would provide
;   when re-combining with old world, only effects after assumption are contributed
;   after re-combining, assumptions are used to unify target keys and generate code to define new keys
; diagram:
;   example of optimal assumption placement
;   case D, where e's depend on D, c's do not depend on D at all, x's depend only on D's effect
; newer ---------------------------------- older
; ... e e e e (assume D = _) x x x D c c c c ...

(data clg-entry
  (clg-data (kvs))  ; plural, allowing SCCs (let-rec) to satisfy partition property
  (clg-obligation (key term env notes))
  (clg-assumption (assumed)))
; (clg-memory-effect ())
; (clg-stream-effect ())
; (clg-reset (marker))
; etc.
(data assumption
  (assume-eq (key0 key1))
  (assume-neq (key0 key1))
  (assume-value (key new-keys value)))
(data cont
  (ohc (cont oh))
  (halt ())
  (return-caller (cont env))
  (return-context (cont env clg-replay)))
(variant (state (focus cont env clg clg-next-key)))

(data penv (penv (syntax vars)))
(define penv-empty (penv dict-empty '()))
(define (penv-syntax-add pe name op)
  (match pe
    ((penv syntax vars) (penv (dict-add syntax name op) vars))))
(define (penv-syntax-del pe name)
  (match pe
    ((penv syntax vars) (penv (dict-del syntax name) vars))))
(define (penv-syntax-get pe name) (dict-get (penv-syntax pe) name))
(define (penv-syntax-rename pe old new)
  (let ((check-vars (lambda (name msg)
                      (match (penv-vars-get pe name)
                        ((nothing) (right '()))
                        ((just _) (left msg))))))
    (do either-monad
      _ <- (check-vars old "cannot rename non-keyword")
      _ <- (check-vars new "rename-target already bound as a non-keyword")
      syn-old <- (maybe->either "cannot rename non-existent keyword"
                                (penv-syntax-get pe old))
      pe0 = (penv-syntax-del pe old)
      (pure (penv-syntax-add pe0 new syn-old)))))
(define (penv-vars-add pe name)
  (match pe
    ((penv syntax vars) (penv syntax (cons name vars)))))
(define (penv-vars-get pe name) (list-index (penv-vars pe) name))

(define (check-arity arity form)
  (if (equal? (length form) arity)
    (right '())
    (left (format "expected arity-~a form but found arity-~a form: ~s"
                  arity (length form) form))))
(define (check-symbol form)
  (if (symbol? form)
    (right '())
    (left (format "expected symbol but found: ~s" form))))

(define (parse pe form)
  (match form
    ('() (right (val (uno))))
    ((? symbol?) (parse-var pe form))
    ((cons op rest) (parse-combination pe op form))
    (_ (left (format "cannot parse: ~s" form)))))
(define (parse-combination pe op form)
  ((if (symbol? op)
     (maybe-from parse-app (penv-syntax-get pe op))
     parse-app)
   pe form))

(define (map-parse pe form) (map-monad either-monad (curry parse pe) form))
(define ((parse-apply proc arity) pe form)
  (do either-monad
    _ <- (check-arity arity form)
    args <- (map-parse pe (cdr form))
    (pure (apply proc args))))
(define (parse-under pe param body)
  (do either-monad
    _ <- (check-symbol param)
    pe = (penv-vars-add pe param)
    (parse pe body)))

(define (parse-var pe name)
  (do either-monad
    idx <- (maybe->either (format "unbound variable '~a'" name)
                          (penv-vars-get pe name))
    (pure (bound idx))))
(define (parse-app pe form)
  (do either-monad
    form <- (map-parse pe form)
    (cons proc args) = form
    (pure
      (let loop ((proc proc) (args args))
        (match args
          ('() proc)
          ((cons arg args) (loop (app proc arg) args)))))))
(define (parse-lam pe form)
  (do either-monad
    _ <- (check-arity 3 form)
    `(,_ ,name ,body) = form
    body <- (parse-under pe name body)
    (pure (val (lam body '())))))
(define (parse-let-rec pe form)
  (define-struct lrdef (name param body))
  (define (lr-def form)
    (do either-monad
      _ <- (check-arity 3 form)
      `(,name ,param ,body) = form
      _ <- (check-symbol name)
      _ <- (check-symbol param)
      (pure (lrdef name param body))))
  (do either-monad
    _ <- (check-arity 3 form)
    `(,_ ,defs ,body) = form
    defs <- (map-monad either-monad lr-def defs)
    names = (map lrdef-name defs)
    pe = (foldl (flip penv-vars-add) pe names)
    defs <- ((flip (curry map-monad either-monad)) defs
              (lambda (def)
                (parse-under pe (lrdef-param def) (lrdef-body def))))
    body <- (parse pe body)
    (pure (let-rec defs body))))
(define (parse-sym pe form)
  (do either-monad
    _ <- (check-arity 2 form)
    `(,_ ,name) = form
    (pure (val (sym name)))))
(define parse-if-eq (parse-apply if-eq 5))
(define parse-pair (parse-apply (compose1 val pair) 3))
(define parse-pair-left (parse-apply pair-left 2))
(define parse-pair-right (parse-apply pair-right 2))

(define penv-init
  (foldr (lambda (keyval pe) (apply (curry penv-syntax-add pe) keyval))
         penv-empty
         `((lam ,parse-lam)
           (sym ,parse-sym)
           (pair ,parse-pair)
           (if-eq ,parse-if-eq)
           (pair-left ,parse-pair-left)
           (pair-right ,parse-pair-right)
           (let-rec ,parse-let-rec))))

; testing
(define tests
  `((lam x x)
    (lam x (lam y x))
    ()
    (pair () ())
    (pair-left (pair () ()))
    (pair-right (pair () ()))
    (sym abc)
    (if-eq (sym abc) (sym def) () ())
    (let-rec ((x y (y x))) (x x))
    (x y)
    (pair () () ())))

(map (lambda (form) (parse penv-init form)) tests)

(displayln "map-parse:")
(map-parse penv-init tests)

;> (define pe (penv-vars-add (penv-vars-add (penv-syntax-add penv-empty 'x 'y) 'z) 'w))
;> (penv-syntax-rename pe 'x 'y)
;(right
 ;(penv
   ;(dict (list (cons 'y (just 'y)) (cons 'x (nothing)) (cons 'x (just 'y))))
   ;'(w z)))
;>