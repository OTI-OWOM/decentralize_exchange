;; Implements basic AMM (Automated Market Maker) functionality

(define-constant contract-owner tx-sender)
(define-constant fee-denominator u1000)
(define-constant fee-numerator u3) ;; 0.3% fee

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-BALANCE (err u101))
(define-constant ERR-INSUFFICIENT-LIQUIDITY (err u102))
(define-constant ERR-ZERO-LIQUIDITY (err u103))
(define-constant ERR-EXPIRED (err u104))
(define-constant ERR-SLIPPAGE-EXCEEDED (err u105))

;; Data variables
(define-data-var total-liquidity uint u0)

;; Data maps
(define-map liquidity-providers
    principal
    uint)

(define-map token-reserves
    { token-x: (string-ascii 32), token-y: (string-ascii 32) }
    { reserve-x: uint, reserve-y: uint })

;; Helper functions
(define-private (min-uint (a uint) (b uint))
    (if (<= a b)
        a
        b))


;; Read-only functions
(define-read-only (get-reserves (token-x (string-ascii 32)) (token-y (string-ascii 32)))
    (match (map-get? token-reserves { token-x: token-x, token-y: token-y })
        reserve-pair (ok reserve-pair)
        (err ERR-ZERO-LIQUIDITY)))

(define-read-only (get-liquidity-provider-balance (provider principal))
    (default-to u0
        (map-get? liquidity-providers provider)))

;; Calculate token output amount for a swap
(define-read-only (get-swap-output 
    (amount-in uint)
    (reserve-in uint)
    (reserve-out uint))
    (let
        (
            (amount-in-with-fee (* amount-in (- fee-denominator fee-numerator)))
            (numerator (* amount-in-with-fee reserve-out))
            (denominator (+ (* reserve-in fee-denominator) amount-in-with-fee))
        )
        (/ numerator denominator)
    ))

;; Public functions
(define-public (add-liquidity
    (token-x (string-ascii 32))
    (token-y (string-ascii 32))
    (amount-x uint)
    (amount-y uint)
    (min-liquidity uint))
    (begin
        (let (
            (reserves (unwrap! (get-reserves token-x token-y) (ok u0)))
            (reserve-x (get reserve-x reserves))
            (reserve-y (get reserve-y reserves))
            (liquidity-minted (if (is-eq reserve-x u0)
                amount-x
                (min-uint
                    (/ (* amount-x (var-get total-liquidity)) reserve-x)
                    (/ (* amount-y (var-get total-liquidity)) reserve-y))))
        )
        
        (asserts! (>= liquidity-minted min-liquidity) ERR-INSUFFICIENT-LIQUIDITY)
        
        ;; Update reserves
        (map-set token-reserves
            { token-x: token-x, token-y: token-y }
            { reserve-x: (+ reserve-x amount-x), 
              reserve-y: (+ reserve-y amount-y) })
        
        ;; Update liquidity
        (var-set total-liquidity (+ (var-get total-liquidity) liquidity-minted))
        (map-set liquidity-providers
            tx-sender
            (+ (get-liquidity-provider-balance tx-sender) liquidity-minted))
        
        (ok liquidity-minted))))


(define-public (remove-liquidity
    (token-x (string-ascii 32))
    (token-y (string-ascii 32))
    (liquidity uint)
    (min-amount-x uint)
    (min-amount-y uint))
    (begin 
        (let (
            (reserves (unwrap! (get-reserves token-x token-y) ERR-ZERO-LIQUIDITY))
            (reserve-x (get reserve-x reserves))
            (reserve-y (get reserve-y reserves))
            (provider-liquidity (get-liquidity-provider-balance tx-sender))
            (amount-x (/ (* liquidity reserve-x) (var-get total-liquidity)))
            (amount-y (/ (* liquidity reserve-y) (var-get total-liquidity)))
        )
        
        (asserts! (>= provider-liquidity liquidity) ERR-INSUFFICIENT-BALANCE)
        (asserts! (>= amount-x min-amount-x) ERR-SLIPPAGE-EXCEEDED)
        (asserts! (>= amount-y min-amount-y) ERR-SLIPPAGE-EXCEEDED)
        
        ;; Update reserves
        (map-set token-reserves
            { token-x: token-x, token-y: token-y }
            { reserve-x: (- reserve-x amount-x),
              reserve-y: (- reserve-y amount-y) })
        
        ;; Update liquidity
        (var-set total-liquidity (- (var-get total-liquidity) liquidity))
        (map-set liquidity-providers
            tx-sender
            (- provider-liquidity liquidity))
        
        (ok { amount-x: amount-x, amount-y: amount-y }))))
