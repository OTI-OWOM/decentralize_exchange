

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

(define-public (swap-exact-tokens
    (token-in (string-ascii 32))
    (token-out (string-ascii 32))
    (amount-in uint)
    (min-amount-out uint)
    (deadline uint))
    (begin
        (let (
            (reserves (unwrap! (get-reserves token-in token-out) ERR-ZERO-LIQUIDITY))
            (reserve-in (get reserve-x reserves))
            (reserve-out (get reserve-y reserves))
            (amount-out (get-swap-output amount-in reserve-in reserve-out))
        )
        
        (asserts! (<= block-height deadline) ERR-EXPIRED)
        (asserts! (>= amount-out min-amount-out) ERR-SLIPPAGE-EXCEEDED)
        
        ;; Update reserves
        (map-set token-reserves
            { token-x: token-in, token-y: token-out }
            { reserve-x: (+ reserve-in amount-in),
              reserve-y: (- reserve-out amount-out) })
        
        (ok amount-out))))

;; Initialize contract
(begin
    (var-set total-liquidity u0))

;; Calculate the optimal amount of token-y needed given amount-x
(define-read-only (get-optimal-amount-y
    (token-x (string-ascii 32))
    (token-y (string-ascii 32))
    (amount-x uint))
    (let (
        (reserves (unwrap! (get-reserves token-x token-y) (err u0)))
        (reserve-x (get reserve-x reserves))
        (reserve-y (get reserve-y reserves))
    )
    (if (is-eq reserve-x u0)
        (ok amount-x)
        (ok (/ (* amount-x reserve-y) reserve-x)))))


;; Calculate the current price of token-y in terms of token-x
(define-read-only (get-price-y-in-x
    (token-x (string-ascii 32))
    (token-y (string-ascii 32)))
    (let (
        (reserves (unwrap! (get-reserves token-x token-y) (err u0)))
        (reserve-x (get reserve-x reserves))
        (reserve-y (get reserve-y reserves))
    )
    (if (or (is-eq reserve-x u0) (is-eq reserve-y u0))
        (err u0)  ;; Using u0 as error code for zero liquidity
        (ok (/ (* reserve-x u1000000) reserve-y)))))  ;; Price multiplied by 1M for precision


;; Get total pool value locked in terms of token-x
(define-read-only (get-total-value-locked
    (token-x (string-ascii 32))
    (token-y (string-ascii 32)))
    (let (
        (reserves (unwrap! (get-reserves token-x token-y) (err u0)))
        (reserve-x (get reserve-x reserves))
        (reserve-y (get reserve-y reserves))
    )
    (ok { reserve-x: reserve-x, 
          reserve-y: reserve-y, 
          total-liquidity: (var-get total-liquidity) })))

;; Get user's share of the pool as a percentage
(define-read-only (get-pool-share (provider principal))
    (let (
        (provider-liquidity (get-liquidity-provider-balance provider))
        (total (var-get total-liquidity))
    )
    (if (is-eq total u0)
        (ok u0)
        (ok (/ (* provider-liquidity u10000) total)))))  ;; Multiplied by 10000 for 2 decimal precision

;; Calculate impermanent loss for a given price change
(define-read-only (calculate-impermanent-loss
    (initial-price uint)
    (current-price uint))
    (let (
        (price-ratio (/ (* current-price u1000000) initial-price))
        (sqrt-ratio (sqrti price-ratio))
    )
    (ok (- (/ (* u2 sqrt-ratio) (+ u1000000 price-ratio)) u1000000))))

;; Calculate the minimum amount of liquidity tokens that should be minted
(define-read-only (get-minimum-liquidity
    (amount-x uint)
    (amount-y uint))
    (let (
        (geometric-mean (sqrti (* amount-x amount-y))))
    (ok (/ geometric-mean u100))))  ;; 1% of geometric mean


;; Calculate accumulated fees for a liquidity provider
(define-read-only (get-accumulated-fees
    (provider principal)
    (token-x (string-ascii 32))
    (token-y (string-ascii 32)))
    (let (
        (provider-share (unwrap! (get-pool-share provider) (err u0)))
        (reserves (unwrap! (get-reserves token-x token-y) (err u0)))
        (total-fees-x (/ (* (get reserve-x reserves) fee-numerator) fee-denominator))
        (total-fees-y (/ (* (get reserve-y reserves) fee-numerator) fee-denominator))
    )
    (ok {
        fees-x: (/ (* total-fees-x provider-share) u10000),
        fees-y: (/ (* total-fees-y provider-share) u10000)
    })))


;; Get volume-based fee tier for a liquidity provider
(define-read-only (get-fee-tier (provider principal))
    (let (
        (provider-liquidity (get-liquidity-provider-balance provider))
    )
    (ok (if (>= provider-liquidity u1000000000)
            u2  ;; 0.2% fee for large LPs
            (if (>= provider-liquidity u100000000)
                u25  ;; 0.25% fee for medium LPs
                u3))))) ;; 0.3% fee for small LPs

;; Predict liquidity mining rewards
(define-read-only (predict-mining-rewards
    (provider principal)
    (blocks uint))
    (let (
        (provider-share (unwrap! (get-pool-share provider) (err u0)))
        (base-reward-per-block u100)  ;; Base reward tokens per block
    )
    (ok (/ (* (* blocks base-reward-per-block) provider-share) u10000))))

